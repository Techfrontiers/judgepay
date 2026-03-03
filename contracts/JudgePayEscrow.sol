// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

// Abstract interface for Chainlink VRF
interface IVRFCoordinator {
    function requestRandomWords(
        bytes32 keyHash,
        uint64 subId,
        uint16 confirmations,
        uint32 gasLimit,
        uint32 numWords
    ) external returns (uint256 requestId);
}

/**
 * @title JudgePay Protocol (V10 - Enterprise 99.99%)
 * @notice Arbitration Infrastructure Layer with True VRF, Time-Gated Reputation, Multi-Sig Governance, and Invariant Checks
 */
contract JudgePayEscrow is ReentrancyGuard, Pausable, AccessControl {
    using SafeERC20 for IERC20;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");

    IERC20 public immutable usdc;
    IVRFCoordinator public vrfCoordinator;

    // Chainlink VRF Config
    uint64 public vrfSubscriptionId;
    bytes32 public vrfKeyHash;
    uint32 public vrfCallbackGasLimit = 2000000;
    
    // Total Value Locked Invariant
    uint256 public totalLockedEscrow;

    enum TaskStatus {
        Open,           
        Locked,         // Claimed by worker
        Submitted,      
        L1_AutoChecks,  
        L2_OracleReview,
        L3_VRFPending,  // Waiting for Chainlink VRF
        L3_HumanJury,   
        Completed,      
        Refunded,       
        Resolved        
    }

    struct Task {
        address requester;          
        address worker;             
        uint256 amount;             
        uint256 createdAt;          
        uint256 deadline;           
        uint256 submitTime;         
        bytes32 descriptionHash;    
        bytes32 outputHash;         
        string outputMetadataURI;   
        TaskStatus status;          
        
        // Oracle Layer
        uint256 oracleConfidenceScore; 
        uint8 requiredOracles;
        uint8 currentOracleVotes;
        uint256 accumulatedOracleScore;
        bytes32 promptHash;         // To verify what the oracle was asked
        string modelVersion;        // To verify which model answered

        // Jury Layer
        uint256 jurySize;           
        uint256 acceptPower;        
        uint256 rejectPower;        
        uint256 disputeDeadline;
        uint256 vrfRequestId;
    }

    mapping(uint256 => Task) public tasks;
    mapping(uint256 => mapping(address => bool)) public hasOracleVoted;
    
    mapping(uint256 => address[]) public taskJurors;
    mapping(uint256 => mapping(address => bool)) public hasVoted;
    mapping(uint256 => mapping(address => bool)) public voteChoice; 
    
    mapping(uint256 => uint256) public vrfToTaskId;

    struct JurorStats {
        uint256 correctVotes;       
        uint256 totalVotes;         
        uint256 weightedScore;      
        uint256 lastVoteTime;       
        uint256 reputationDecay;    
        uint256 maxTaskValueResolved;
        uint256 registrationTime;   
    }
    
    mapping(address => JurorStats) public jurors;
    address[] public activeJurorPool;
    mapping(address => bool) public isJurorInPool;
    
    uint256 public taskCount;

    event TaskCreated(uint256 indexed taskId, address indexed requester, uint256 amount);
    event TaskClaimed(uint256 indexed taskId, address indexed worker);
    event WorkSubmitted(uint256 indexed taskId, address indexed worker, string metadataURI);
    event L2_OracleVoted(uint256 indexed taskId, address indexed oracle, uint256 confidenceScore);
    event VRFRequested(uint256 indexed taskId, uint256 indexed requestId);
    event L3_JurorSelected(uint256 indexed taskId, address indexed juror);
    event L3_Voted(uint256 indexed taskId, address indexed juror, bool approve, uint256 votingPower);
    event DisputeResolved(uint256 indexed taskId, bool workerWins);

    // Modifier to strictly check the TVL invariant
    modifier checkInvariant() {
        _;
        require(usdc.balanceOf(address(this)) >= totalLockedEscrow, "Invariant broken: Insufficient funds");
    }

    constructor(
        address _usdc, 
        address _vrfCoordinator, 
        uint64 _subId, 
        bytes32 _keyHash,
        address _multisigAdmin
    ) {
        usdc = IERC20(_usdc);
        vrfCoordinator = IVRFCoordinator(_vrfCoordinator);
        vrfSubscriptionId = _subId;
        vrfKeyHash = _keyHash;
        
        _grantRole(DEFAULT_ADMIN_ROLE, _multisigAdmin);
        _grantRole(ADMIN_ROLE, _multisigAdmin);
    }

    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    function registerAsJuror() external whenNotPaused {
        require(!isJurorInPool[msg.sender], "Already registered");
        activeJurorPool.push(msg.sender);
        isJurorInPool[msg.sender] = true;
        
        if (jurors[msg.sender].totalVotes == 0) {
            jurors[msg.sender].weightedScore = 0;
            jurors[msg.sender].reputationDecay = 1;
            jurors[msg.sender].maxTaskValueResolved = 0;
            jurors[msg.sender].registrationTime = block.timestamp;
        }
    }

    function createTask(
        bytes32 _descriptionHash,
        uint256 _amount,
        uint256 _deadlineHours,
        uint8 _requiredOracles,
        uint256 _baseJurySize
    ) external nonReentrant whenNotPaused checkInvariant returns (uint256) {
        require(_amount > 0, "Invalid amount");
        require(_deadlineHours > 0, "Invalid deadline");
        
        usdc.safeTransferFrom(msg.sender, address(this), _amount);
        totalLockedEscrow += _amount;

        uint256 taskId = taskCount++;
        
        tasks[taskId] = Task({
            requester: msg.sender,
            worker: address(0),
            amount: _amount,
            createdAt: block.timestamp,
            deadline: block.timestamp + (_deadlineHours * 1 hours),
            submitTime: 0,
            descriptionHash: _descriptionHash,
            outputHash: bytes32(0),
            outputMetadataURI: "",
            status: TaskStatus.Open,
            requiredOracles: _requiredOracles,
            currentOracleVotes: 0,
            accumulatedOracleScore: 0,
            oracleConfidenceScore: 0,
            promptHash: bytes32(0),
            modelVersion: "",
            jurySize: _baseJurySize,
            acceptPower: 0,
            rejectPower: 0,
            disputeDeadline: 0,
            vrfRequestId: 0
        });

        emit TaskCreated(taskId, msg.sender, _amount);
        return taskId;
    }

    function claimTask(uint256 _taskId) external nonReentrant whenNotPaused {
        Task storage task = tasks[_taskId];
        require(task.status == TaskStatus.Open, "Not open");
        require(block.timestamp < task.deadline, "Expired");
        require(msg.sender != task.requester, "Requester cannot claim");

        task.worker = msg.sender;
        task.status = TaskStatus.Locked;
        emit TaskClaimed(_taskId, msg.sender);
    }

    function submitWork(uint256 _taskId, bytes32 _outputHash, string memory _metadataURI) external whenNotPaused {
        Task storage task = tasks[_taskId];
        require(task.status == TaskStatus.Locked, "Not locked");
        require(task.worker == msg.sender, "Not worker");
        require(block.timestamp < task.deadline, "Deadline passed");

        task.outputHash = _outputHash;
        task.outputMetadataURI = _metadataURI; 
        task.submitTime = block.timestamp;
        
        if (task.requiredOracles == 0) {
            task.status = TaskStatus.Submitted;
            task.disputeDeadline = block.timestamp + 48 hours;
        } else {
            task.status = TaskStatus.L2_OracleReview;
        }

        emit WorkSubmitted(_taskId, msg.sender, _metadataURI);
    }

    // Requester manually accepts without dispute
    function acceptWork(uint256 _taskId) external nonReentrant whenNotPaused {
        Task storage task = tasks[_taskId];
        require(task.status == TaskStatus.Submitted, "Invalid state");
        require(msg.sender == task.requester, "Not requester");

        _release(_taskId, true);
    }

    // Manual Dispute if Oracle is bypassed
    function dispute(uint256 _taskId) external whenNotPaused {
        Task storage task = tasks[_taskId];
        require(task.status == TaskStatus.Submitted, "Invalid state");
        require(msg.sender == task.requester, "Not requester");
        require(block.timestamp <= task.disputeDeadline, "Dispute window closed");

        _escalateToJury(_taskId);
    }

    // Claim if requester goes silent
    function claimIfSilent(uint256 _taskId) external nonReentrant whenNotPaused {
        Task storage task = tasks[_taskId];
        require(task.status == TaskStatus.Submitted, "Invalid state");
        require(block.timestamp > task.disputeDeadline, "Too early");

        _release(_taskId, true);
    }

    // --- ORACLE LAYER ---

    function submitOracleScore(
        uint256 _taskId, 
        uint256 _confidenceScore,
        bytes32 _promptHash,
        string memory _modelVersion
    ) external nonReentrant whenNotPaused onlyRole(ORACLE_ROLE) {
        Task storage task = tasks[_taskId];
        require(task.status == TaskStatus.L2_OracleReview, "Not in L2 review");
        require(!hasOracleVoted[_taskId][msg.sender], "Already voted");

        hasOracleVoted[_taskId][msg.sender] = true;
        task.currentOracleVotes++;
        task.accumulatedOracleScore += _confidenceScore;
        
        // Store verification data (Last oracle's data is kept for simplicity, in production emit via event for indexing)
        task.promptHash = _promptHash;
        task.modelVersion = _modelVersion;

        emit L2_OracleVoted(_taskId, msg.sender, _confidenceScore);

        if (task.currentOracleVotes == task.requiredOracles) {
            _processConfidenceMatrix(_taskId);
        }
    }

    function _processConfidenceMatrix(uint256 _taskId) internal {
        Task storage task = tasks[_taskId];
        task.oracleConfidenceScore = task.accumulatedOracleScore / task.requiredOracles;

        if (task.oracleConfidenceScore >= 92) {
            _release(_taskId, true);
        } else if (task.oracleConfidenceScore <= 30) {
            _release(_taskId, false);
        } else {
            _escalateToJury(_taskId);
        }
    }

    // --- VRF JURY ---

    function _escalateToJury(uint256 _taskId) internal {
        Task storage task = tasks[_taskId];
        task.status = TaskStatus.L3_VRFPending;
        
        uint256 requestId = vrfCoordinator.requestRandomWords(
            vrfKeyHash,
            vrfSubscriptionId,
            3, 
            vrfCallbackGasLimit,
            1 
        );
        task.vrfRequestId = requestId;
        vrfToTaskId[requestId] = _taskId;
        
        emit VRFRequested(_taskId, requestId);
    }

    function fulfillRandomWords(uint256 requestId, uint256[] memory randomWords) external {
        uint256 _taskId = vrfToTaskId[requestId];
        Task storage task = tasks[_taskId];
        require(task.status == TaskStatus.L3_VRFPending, "Not pending VRF");
        
        uint256 seed = randomWords[0];
        uint256 poolSize = activeJurorPool.length;
        uint256 selectedCount = 0;
        uint256 attempts = 0;
        
        task.status = TaskStatus.L3_HumanJury;
        
        while (selectedCount < task.jurySize && attempts < poolSize * 3) {
            uint256 index = uint256(keccak256(abi.encodePacked(seed, attempts))) % poolSize;
            address candidate = activeJurorPool[index];
            JurorStats storage stats = jurors[candidate];
            
            bool isMature = block.timestamp >= stats.registrationTime + 7 days;
            
            if (candidate != task.requester && candidate != task.worker && !hasVoted[_taskId][candidate] && isMature) {
                taskJurors[_taskId].push(candidate);
                hasVoted[_taskId][candidate] = false;
                emit L3_JurorSelected(_taskId, candidate);
                selectedCount++;
            }
            attempts++;
        }
    }

    function castVote(uint256 _taskId, bool _approve) external nonReentrant whenNotPaused {
        Task storage task = tasks[_taskId];
        require(task.status == TaskStatus.L3_HumanJury, "Not in L3 phase");
        
        bool isSelected = false;
        for (uint i = 0; i < taskJurors[_taskId].length; i++) {
            if (taskJurors[_taskId][i] == msg.sender) {
                isSelected = true;
                break;
            }
        }
        require(isSelected, "Not selected");
        require(!hasVoted[_taskId][msg.sender], "Already voted");

        hasVoted[_taskId][msg.sender] = true;
        voteChoice[_taskId][msg.sender] = _approve;
        
        JurorStats storage stats = jurors[msg.sender];
        if (block.timestamp > stats.lastVoteTime + 30 days && stats.weightedScore > 10) {
            stats.weightedScore -= (stats.weightedScore / 10);
        }
        
        uint256 power = stats.weightedScore;

        if (_approve) {
            task.acceptPower += power;
        } else {
            task.rejectPower += power;
        }
        
        stats.lastVoteTime = block.timestamp;
        
        emit L3_Voted(_taskId, msg.sender, _approve, power);

        uint256 voteCount = 0;
        for (uint i = 0; i < taskJurors[_taskId].length; i++) {
            if (hasVoted[_taskId][taskJurors[_taskId][i]]) voteCount++;
        }

        if (voteCount == taskJurors[_taskId].length) {
            _resolveJury(_taskId);
        }
    }

    function _resolveJury(uint256 _taskId) internal {
        Task storage task = tasks[_taskId];
        bool workerWins = task.acceptPower >= task.rejectPower; 
        
        for (uint i = 0; i < taskJurors[_taskId].length; i++) {
            address juror = taskJurors[_taskId][i];
            JurorStats storage stats = jurors[juror];
            
            stats.totalVotes++;
            
            if (voteChoice[_taskId][juror] == workerWins) {
                stats.correctVotes++;
                uint256 logValue = _log10(task.amount / (10**6)); 
                if (logValue == 0) logValue = 1;
                
                uint256 boost = (stats.totalVotes * logValue) / stats.reputationDecay;
                stats.weightedScore = _min(stats.weightedScore + boost, 10000);
            } else {
                stats.reputationDecay += 5; 
                stats.weightedScore = stats.weightedScore / stats.reputationDecay;
            }
        }

        _release(_taskId, workerWins);
    }
    
    function _release(uint256 _taskId, bool _approved) internal checkInvariant {
        Task storage task = tasks[_taskId];
        require(task.amount <= totalLockedEscrow, "Accounting error");
        
        totalLockedEscrow -= task.amount;
        task.status = TaskStatus.Resolved;
        
        if (_approved) {
            usdc.safeTransfer(task.worker, task.amount);
        } else {
            usdc.safeTransfer(task.requester, task.amount);
        }

        emit DisputeResolved(_taskId, _approved);
    }

    function _log10(uint256 x) internal pure returns (uint256) {
        uint256 res = 0;
        while (x >= 10) {
            x /= 10;
            res++;
        }
        return res;
    }
    
    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
    
    // Fallback for timeout
    function cancelJobIfTimeout(uint256 _taskId) external nonReentrant whenNotPaused {
        Task storage task = tasks[_taskId];
        require(task.status == TaskStatus.Open, "Not open");
        require(block.timestamp > task.deadline, "Not expired");
        require(msg.sender == task.requester, "Not requester");

        _release(_taskId, false);
    }
    
    // Ensure invariant is maintained
    function checkEscrowHealth() external view returns (bool) {
        return totalLockedEscrow == usdc.balanceOf(address(this));
    }
}
