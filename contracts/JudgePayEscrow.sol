// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title JudgePay Protocol (V7 - The Judicial Layer of AI Economy)
 * @notice 3-Layer Arbitration, Dynamic Soulbound Reputation, and Multi-Oracle Integration
 */
contract JudgePayEscrow is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdc;

    enum TaskStatus {
        Open,           
        Submitted,      
        L1_AutoChecks,  // Deterministic checks (Hash, length, format)
        L2_OracleReview,// Multi-Oracle LLM review
        L3_HumanJury,   // Final override by Human/High-Reputation Jurors
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
        bytes32 descriptionHash;    // Blinded identity
        bytes32 outputHash;         // Blinded identity
        TaskStatus status;          
        
        // L1 Data
        uint256 minLength;
        uint256 maxLength;
        
        // L2 Data (Multi-Oracle)
        uint256 oracleConfidenceScore; // 0-100 aggregated score
        uint8 requiredOracles;
        uint8 currentOracleVotes;
        uint256 accumulatedOracleScore;

        // L3 Data (Jury)
        uint256 jurySize;           
        uint256 acceptPower;        
        uint256 rejectPower;        
        uint256 disputeStartTime;
    }

    // Task ID => Task
    mapping(uint256 => Task) public tasks;
    
    // Task ID => L2 Oracle Votes
    mapping(uint256 => mapping(address => bool)) public hasOracleVoted;
    
    // Task ID => L3 Jurors
    mapping(uint256 => address[]) public taskJurors;
    mapping(uint256 => mapping(address => bool)) public hasVoted;
    mapping(uint256 => mapping(address => bool)) public voteChoice; 
    
    // Dynamic Reputation System (Soulbound Credit)
    struct JurorStats {
        uint256 correctVotes;       
        uint256 totalVotes;         
        uint256 weightedScore;      // VotingPower = f(accuracy, participation, diversity)
        uint256 lastVoteTime;       
        uint256 reputationDecay;    // Penalty multiplier for voting against majority
    }
    
    mapping(address => JurorStats) public jurors;
    address[] public activeJurorPool;
    mapping(address => bool) public isJurorInPool;
    mapping(address => bool) public isAuthorizedOracle;
    
    uint256 public taskCount;

    // Events
    event TaskCreated(uint256 indexed taskId, address indexed requester, uint256 amount);
    event TaskClaimed(uint256 indexed taskId, address indexed worker);
    event WorkSubmitted(uint256 indexed taskId, address indexed worker);
    
    // Layer Events
    event L1_Passed(uint256 indexed taskId);
    event L1_Failed(uint256 indexed taskId, string reason);
    event L2_OracleVoted(uint256 indexed taskId, address indexed oracle, uint256 confidenceScore);
    event L2_Completed(uint256 indexed taskId, uint256 finalConfidence, bool escalatedToL3);
    
    event L3_DisputeRaised(uint256 indexed taskId, address indexed raiser);
    event L3_JurorSelected(uint256 indexed taskId, address indexed juror);
    event L3_Voted(uint256 indexed taskId, address indexed juror, bool approve, uint256 votingPower);
    event DisputeResolved(uint256 indexed taskId, bool workerWins);

    constructor(address _usdc) Ownable(msg.sender) {
        usdc = IERC20(_usdc);
    }

    // --- ORACLE & JUROR REGISTRATION ---
    
    function setOracleStatus(address _oracle, bool _status) external onlyOwner {
        isAuthorizedOracle[_oracle] = _status;
    }

    function registerAsJuror() external {
        require(!isJurorInPool[msg.sender], "Already registered");
        activeJurorPool.push(msg.sender);
        isJurorInPool[msg.sender] = true;
        
        if (jurors[msg.sender].totalVotes == 0) {
            // New jurors start with low power (Time is the new stake)
            jurors[msg.sender].weightedScore = 1;
            jurors[msg.sender].reputationDecay = 1;
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
    ) external nonReentrant returns (uint256) {
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

    function claimTask(uint256 _taskId) external nonReentrant {
        Task storage task = tasks[_taskId];
        require(task.status == TaskStatus.Open, "Not open");
        require(task.worker == address(0), "Already claimed");
        require(block.timestamp < task.deadline, "Expired");
        require(msg.sender != task.requester, "Requester cannot claim");

        task.worker = msg.sender;
        emit TaskClaimed(_taskId, msg.sender);
    }

    // --- LAYER 1: DETERMINISTIC CHECKS ---
    
    function submitWork(uint256 _taskId, bytes32 _outputHash, uint256 _outputLength) external {
        Task storage task = tasks[_taskId];
        require(task.status == TaskStatus.Open, "Not open");
        require(task.worker == msg.sender, "Not worker");
        require(block.timestamp < task.deadline, "Deadline passed");

        task.outputHash = _outputHash;
        task.submitTime = block.timestamp;
        
        // L1 Check: Simple deterministic boundaries
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
        emit WorkSubmitted(_taskId, msg.sender);

        // If no Oracles needed, auto-complete
        if (task.requiredOracles == 0) {
            task.status = TaskStatus.Completed;
            usdc.safeTransfer(task.worker, task.amount);
            emit TaskApproved(_taskId);
        } else {
            task.status = TaskStatus.L2_OracleReview;
        }
    }

    // --- LAYER 2: MULTI-ORACLE AI REVIEW ---

    function submitOracleScore(uint256 _taskId, uint256 _confidenceScore) external nonReentrant {
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

        // Confidence-Based Escalation
        if (task.oracleConfidenceScore >= 90) {
            // High confidence = Auto Approve
            task.status = TaskStatus.Completed;
            usdc.safeTransfer(task.worker, task.amount);
            emit L2_Completed(_taskId, task.oracleConfidenceScore, false);
            emit TaskApproved(_taskId);
        } else if (task.oracleConfidenceScore <= 30) {
            // Low confidence = Auto Reject
            task.status = TaskStatus.Refunded;
            usdc.safeTransfer(task.requester, task.amount);
            emit L2_Completed(_taskId, task.oracleConfidenceScore, false);
        } else {
            // Ambiguous (31-89) = Escalate to L3 Jury
            task.status = TaskStatus.L3_HumanJury;
            task.disputeStartTime = block.timestamp;
            emit L2_Completed(_taskId, task.oracleConfidenceScore, true);
            _selectRandomJurors(_taskId);
        }
    }

    // --- LAYER 3: BLIND RANDOM JURY (SOULBOUND REPUTATION) ---

    function _selectRandomJurors(uint256 _taskId) internal {
        Task storage task = tasks[_taskId];
        uint256 poolSize = activeJurorPool.length;
        
        // Pseudo-random (Use Chainlink VRF on Mainnet)
        uint256 seed = uint256(keccak256(abi.encodePacked(block.timestamp, block.prevrandao, _taskId)));
        uint256 selectedCount = 0;
        uint256 attempts = 0;
        
        while (selectedCount < task.jurySize && attempts < poolSize * 2) {
            uint256 index = uint256(keccak256(abi.encodePacked(seed, attempts))) % poolSize;
            address candidate = activeJurorPool[index];
            
            if (candidate != task.requester && candidate != task.worker && !hasVoted[_taskId][candidate]) {
                taskJurors[_taskId].push(candidate);
                hasVoted[_taskId][candidate] = false;
                emit L3_JurorSelected(_taskId, candidate);
                selectedCount++;
            }
            attempts++;
        }
    }

    function castVote(uint256 _taskId, bool _approve) external nonReentrant {
        Task storage task = tasks[_taskId];
        require(task.status == TaskStatus.L3_HumanJury, "Not in L3 Jury phase");
        
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
        
        // VOTE POWER: Time is the new stake + participation diversity
        uint256 power = jurors[msg.sender].weightedScore;

        if (_approve) {
            task.acceptPower += power;
        } else {
            task.rejectPower += power;
        }
        
        jurors[msg.sender].lastVoteTime = block.timestamp;
        
        emit L3_Voted(_taskId, msg.sender, _approve, power);

        // Check if all selected jurors have voted
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

        bool workerWins = task.acceptPower >= task.rejectPower; // Tie goes to worker
        
        // Update Reputation Scores (Soulbound Credit)
        for (uint i = 0; i < taskJurors[_taskId].length; i++) {
            address juror = taskJurors[_taskId][i];
            JurorStats storage stats = jurors[juror];
            
            stats.totalVotes++;
            
            if (voteChoice[_taskId][juror] == workerWins) {
                // Prediction Market Layer: Voted correctly
                stats.correctVotes++;
                // Boost power (Time/Participation multiplier)
                uint256 boost = (stats.totalVotes * 10) / (stats.reputationDecay == 0 ? 1 : stats.reputationDecay);
                stats.weightedScore = _min(stats.weightedScore + boost, 10000);
            } else {
                // Voted incorrectly: Reputation decays heavily
                stats.reputationDecay += 2; // Penalty grows exponentially for bad actors
                stats.weightedScore = stats.weightedScore / stats.reputationDecay;
                
                if (stats.weightedScore == 0) {
                    stats.weightedScore = 1; // Minimum floor
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
    
    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
    
    // Fallbacks
    function claimTimeout(uint256 _taskId) external nonReentrant {
        Task storage task = tasks[_taskId];
        require(task.status == TaskStatus.Open, "Not open");
        require(block.timestamp > task.deadline, "Not expired");
        require(msg.sender == task.requester, "Not requester");

        task.status = TaskStatus.Refunded;
        usdc.safeTransfer(task.requester, task.amount);
    }

    function claimTimeoutAfterSubmit(uint256 _taskId) external nonReentrant {
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
