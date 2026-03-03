// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title JudgePay Protocol (V8 - Enterprise Grade Arbitration)
 * @notice 3-Layer Arbitration, Dynamic Soulbound Reputation, Tiered Selection, Emergency Stops
 */
contract JudgePayEscrow is ReentrancyGuard, Ownable, Pausable {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdc;

    enum TaskStatus {
        Open,           
        Submitted,      
        L1_AutoChecks,  
        L2_OracleReview,
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
        string outputMetadataURI;   // IPFS CID or URL containing structured proof
        TaskStatus status;          
        
        // L1 Data
        uint256 minLength;
        uint256 maxLength;
        
        // L2 Data (Multi-Oracle)
        uint256 oracleConfidenceScore; 
        uint8 requiredOracles;
        uint8 currentOracleVotes;
        uint256 accumulatedOracleScore;

        // L3 Data (Jury)
        uint256 jurySize;           
        uint256 acceptPower;        
        uint256 rejectPower;        
        uint256 disputeStartTime;
    }

    mapping(uint256 => Task) public tasks;
    mapping(uint256 => mapping(address => bool)) public hasOracleVoted;
    
    mapping(uint256 => address[]) public taskJurors;
    mapping(uint256 => mapping(address => bool)) public hasVoted;
    mapping(uint256 => mapping(address => bool)) public voteChoice; 
    
    // Dynamic Reputation System (Soulbound Credit)
    struct JurorStats {
        uint256 correctVotes;       
        uint256 totalVotes;         
        uint256 weightedScore;      
        uint256 lastVoteTime;       
        uint256 reputationDecay;    
        uint256 maxTaskValueResolved; // Track the highest value task they successfully judged
    }
    
    mapping(address => JurorStats) public jurors;
    address[] public activeJurorPool;
    mapping(address => bool) public isJurorInPool;
    mapping(address => bool) public isAuthorizedOracle;
    
    // For pseudo-VRF (Admin can update seed periodically until real VRF is used)
    uint256 private globalEntropySeed;
    
    uint256 public taskCount;

    // Events
    event TaskCreated(uint256 indexed taskId, address indexed requester, uint256 amount);
    event TaskClaimed(uint256 indexed taskId, address indexed worker);
    event WorkSubmitted(uint256 indexed taskId, address indexed worker, string metadataURI);
    
    event L1_Passed(uint256 indexed taskId);
    event L1_Failed(uint256 indexed taskId, string reason);
    event L2_OracleVoted(uint256 indexed taskId, address indexed oracle, uint256 confidenceScore);
    event L2_Completed(uint256 indexed taskId, uint256 finalConfidence, bool escalatedToL3);
    
    event L3_DisputeRaised(uint256 indexed taskId, address indexed raiser);
    event L3_JurorSelected(uint256 indexed taskId, address indexed juror);
    event L3_Voted(uint256 indexed taskId, address indexed juror, bool approve, uint256 votingPower);
    event DisputeResolved(uint256 indexed taskId, bool workerWins);
    
    event JurorSlashedOffPool(address indexed juror, string reason);

    constructor(address _usdc) Ownable(msg.sender) {
        usdc = IERC20(_usdc);
    }

    // --- EMERGENCY CONTROLS ---
    
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // Update entropy for pseudo-VRF manually to prevent miner manipulation
    function updateEntropy(uint256 _newSeed) external onlyOwner {
        globalEntropySeed = _newSeed;
    }

    // --- ORACLE & JUROR REGISTRATION ---
    
    function setOracleStatus(address _oracle, bool _status) external onlyOwner {
        isAuthorizedOracle[_oracle] = _status;
    }

    function registerAsJuror() external whenNotPaused {
        require(!isJurorInPool[msg.sender], "Already registered");
        activeJurorPool.push(msg.sender);
        isJurorInPool[msg.sender] = true;
        
        if (jurors[msg.sender].totalVotes == 0) {
            jurors[msg.sender].weightedScore = 1;
            jurors[msg.sender].reputationDecay = 1;
            jurors[msg.sender].maxTaskValueResolved = 0;
        }
    }

    // --- CORE ESCROW ---

    function createTask(
        bytes32 _descriptionHash,
        uint256 _amount,
        uint256 _deadlineHours,
        uint256 _minLength,
        uint256 _maxLength,
        uint8 _requiredOracles,
        uint256 _jurySize
    ) external nonReentrant whenNotPaused returns (uint256) {
        require(_amount > 0, "Amount must be > 0");
        require(_deadlineHours > 0, "Deadline must be > 0");
        require(_jurySize % 2 == 1, "Jury size must be odd");
        
        usdc.safeTransferFrom(msg.sender, address(this), _amount);

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
            minLength: _minLength,
            maxLength: _maxLength,
            requiredOracles: _requiredOracles,
            currentOracleVotes: 0,
            accumulatedOracleScore: 0,
            oracleConfidenceScore: 0,
            jurySize: _jurySize,
            acceptPower: 0,
            rejectPower: 0,
            disputeStartTime: 0
        });

        emit TaskCreated(taskId, msg.sender, _amount);
        return taskId;
    }

    function claimTask(uint256 _taskId) external nonReentrant whenNotPaused {
        Task storage task = tasks[_taskId];
        require(task.status == TaskStatus.Open, "Not open");
        require(task.worker == address(0), "Already claimed");
        require(block.timestamp < task.deadline, "Expired");
        require(msg.sender != task.requester, "Requester cannot claim");

        task.worker = msg.sender;
        emit TaskClaimed(_taskId, msg.sender);
    }

    // --- LAYER 1: DETERMINISTIC CHECKS & PROOF METADATA ---
    
    function submitWork(uint256 _taskId, bytes32 _outputHash, uint256 _outputLength, string memory _metadataURI) external whenNotPaused {
        Task storage task = tasks[_taskId];
        require(task.status == TaskStatus.Open, "Not open");
        require(task.worker == msg.sender, "Not worker");
        require(block.timestamp < task.deadline, "Deadline passed");

        task.outputHash = _outputHash;
        task.outputMetadataURI = _metadataURI; // Store IPFS link to the actual work for Jurors to verify
        task.submitTime = block.timestamp;
        
        if (task.minLength > 0 && _outputLength < task.minLength) {
            task.status = TaskStatus.Refunded;
            usdc.safeTransfer(task.requester, task.amount);
            emit L1_Failed(_taskId, "Output too short");
            return;
        }
        
        if (task.maxLength > 0 && _outputLength > task.maxLength) {
            task.status = TaskStatus.Refunded;
            usdc.safeTransfer(task.requester, task.amount);
            emit L1_Failed(_taskId, "Output too long");
            return;
        }

        emit L1_Passed(_taskId);
        emit WorkSubmitted(_taskId, msg.sender, _metadataURI);

        if (task.requiredOracles == 0) {
            task.status = TaskStatus.Completed;
            usdc.safeTransfer(task.worker, task.amount);
            emit TaskApproved(_taskId);
        } else {
            task.status = TaskStatus.L2_OracleReview;
        }
    }

    // --- LAYER 2: MULTI-ORACLE AI REVIEW ---

    function submitOracleScore(uint256 _taskId, uint256 _confidenceScore) external nonReentrant whenNotPaused {
        Task storage task = tasks[_taskId];
        require(task.status == TaskStatus.L2_OracleReview, "Not in L2 review");
        require(isAuthorizedOracle[msg.sender], "Not authorized oracle");
        require(!hasOracleVoted[_taskId][msg.sender], "Oracle already voted");
        require(_confidenceScore <= 100, "Score max 100");

        hasOracleVoted[_taskId][msg.sender] = true;
        task.currentOracleVotes++;
        task.accumulatedOracleScore += _confidenceScore;

        emit L2_OracleVoted(_taskId, msg.sender, _confidenceScore);

        if (task.currentOracleVotes == task.requiredOracles) {
            _processL2Completion(_taskId);
        }
    }

    function _processL2Completion(uint256 _taskId) internal {
        Task storage task = tasks[_taskId];
        task.oracleConfidenceScore = task.accumulatedOracleScore / task.requiredOracles;

        if (task.oracleConfidenceScore >= 90) {
            task.status = TaskStatus.Completed;
            usdc.safeTransfer(task.worker, task.amount);
            emit L2_Completed(_taskId, task.oracleConfidenceScore, false);
            emit TaskApproved(_taskId);
        } else if (task.oracleConfidenceScore <= 30) {
            task.status = TaskStatus.Refunded;
            usdc.safeTransfer(task.requester, task.amount);
            emit L2_Completed(_taskId, task.oracleConfidenceScore, false);
        } else {
            task.status = TaskStatus.L3_HumanJury;
            task.disputeStartTime = block.timestamp;
            emit L2_Completed(_taskId, task.oracleConfidenceScore, true);
            _selectRandomJurors(_taskId);
        }
    }

    // --- LAYER 3: BLIND RANDOM TIERED JURY ---

    function _selectRandomJurors(uint256 _taskId) internal {
        Task storage task = tasks[_taskId];
        uint256 poolSize = activeJurorPool.length;
        
        // Pseudo-random using combination of block data and manual entropy
        uint256 seed = uint256(keccak256(abi.encodePacked(block.timestamp, block.prevrandao, globalEntropySeed, _taskId)));
        uint256 selectedCount = 0;
        uint256 attempts = 0;
        
        while (selectedCount < task.jurySize && attempts < poolSize * 3) {
            uint256 index = uint256(keccak256(abi.encodePacked(seed, attempts))) % poolSize;
            address candidate = activeJurorPool[index];
            
            // Tiering Guardrail: High value tasks require experienced jurors
            bool isExperiencedEnough = true;
            if (task.amount > 1000 * 10**6) { // If task > $1000
                isExperiencedEnough = jurors[candidate].maxTaskValueResolved >= (task.amount / 10); // Must have done $100+ tasks
            }
            
            if (candidate != task.requester && candidate != task.worker && !hasVoted[_taskId][candidate] && isExperiencedEnough) {
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
        require(isSelected, "Not selected for this jury");
        require(!hasVoted[_taskId][msg.sender], "Already voted");

        hasVoted[_taskId][msg.sender] = true;
        voteChoice[_taskId][msg.sender] = _approve;
        
        // VOTE POWER: Weight scales with Task Value to prevent low-value farming manipulating high-value tasks
        uint256 power = jurors[msg.sender].weightedScore;
        // Weight multiplier based on past experience vs current task value
        uint256 taskMultiplier = 1;
        if (task.amount > jurors[msg.sender].maxTaskValueResolved && jurors[msg.sender].maxTaskValueResolved > 0) {
            // Dilute power if they are punching above their weight class
            power = power / 2;
        } else {
            // Boost power if they are veteran of this tier
            taskMultiplier = 2;
        }

        if (_approve) {
            task.acceptPower += (power * taskMultiplier);
        } else {
            task.rejectPower += (power * taskMultiplier);
        }
        
        jurors[msg.sender].lastVoteTime = block.timestamp;
        
        emit L3_Voted(_taskId, msg.sender, _approve, power);

        uint256 voteCount = 0;
        for (uint i = 0; i < taskJurors[_taskId].length; i++) {
            if (hasVoted[_taskId][taskJurors[_taskId][i]]) voteCount++;
        }

        if (voteCount == taskJurors[_taskId].length) {
            _resolveDispute(_taskId);
        }
    }

    function _resolveDispute(uint256 _taskId) internal {
        Task storage task = tasks[_taskId];
        task.status = TaskStatus.Resolved;

        bool workerWins = task.acceptPower >= task.rejectPower; 
        
        for (uint i = 0; i < taskJurors[_taskId].length; i++) {
            address juror = taskJurors[_taskId][i];
            JurorStats storage stats = jurors[juror];
            
            stats.totalVotes++;
            
            if (voteChoice[_taskId][juror] == workerWins) {
                stats.correctVotes++;
                uint256 boost = (stats.totalVotes * 10) / (stats.reputationDecay == 0 ? 1 : stats.reputationDecay);
                stats.weightedScore = _min(stats.weightedScore + boost, 10000);
                
                // Update their max tier cleared
                if (task.amount > stats.maxTaskValueResolved) {
                    stats.maxTaskValueResolved = task.amount;
                }
            } else {
                // Outlier Detection & Severe Penalization
                stats.reputationDecay += 3; // Aggressive compounding penalty
                stats.weightedScore = stats.weightedScore / stats.reputationDecay;
                
                if (stats.weightedScore < 2) {
                    isJurorInPool[juror] = false;
                    _removeFromPool(juror);
                    emit JurorSlashedOffPool(juror, "Reputation dropped below minimum threshold");
                }
            }
        }

        if (workerWins) {
            usdc.safeTransfer(task.worker, task.amount);
        } else {
            usdc.safeTransfer(task.requester, task.amount);
        }

        emit DisputeResolved(_taskId, workerWins);
    }
    
    function _removeFromPool(address _juror) internal {
        for (uint i = 0; i < activeJurorPool.length; i++) {
            if (activeJurorPool[i] == _juror) {
                activeJurorPool[i] = activeJurorPool[activeJurorPool.length - 1];
                activeJurorPool.pop();
                break;
            }
        }
    }
    
    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
    
    // Fallbacks
    function claimTimeout(uint256 _taskId) external nonReentrant whenNotPaused {
        Task storage task = tasks[_taskId];
        require(task.status == TaskStatus.Open, "Not open");
        require(block.timestamp > task.deadline, "Not expired");
        require(msg.sender == task.requester, "Not requester");

        task.status = TaskStatus.Refunded;
        usdc.safeTransfer(task.requester, task.amount);
    }

    function claimTimeoutAfterSubmit(uint256 _taskId) external nonReentrant whenNotPaused {
        Task storage task = tasks[_taskId];
        require(
            task.status == TaskStatus.Submitted || 
            task.status == TaskStatus.L2_OracleReview, 
            "Not in review state"
        );
        require(block.timestamp > task.submitTime + 48 hours, "Grace period active");
        require(msg.sender == task.worker, "Only worker");
        
        task.status = TaskStatus.Completed;
        usdc.safeTransfer(task.worker, task.amount);
    }
}
