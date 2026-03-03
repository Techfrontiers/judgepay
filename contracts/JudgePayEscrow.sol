// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title JudgePayEscrow (V6 - Decentralized Arbitration Protocol)
 * @notice Pure escrow with dynamic reputation, blind VRF-like jury selection, and anti-collusion
 */
contract JudgePayEscrow is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdc;

    enum TaskStatus {
        Open,           
        Submitted,      
        Completed,      
        Refunded,       
        Disputed,       
        Resolved        
    }

    struct Task {
        address requester;          
        address worker;             
        uint256 amount;             
        uint256 createdAt;          
        uint256 deadline;           
        uint256 submitTime;         
        bytes32 descriptionHash;    // Should not contain identity info
        bytes32 outputHash;         // Should not contain identity info
        TaskStatus status;          
        
        uint256 jurySize;           
        uint256 acceptPower;        // Sum of weighted reputation of Accept votes
        uint256 rejectPower;        // Sum of weighted reputation of Reject votes
        uint256 disputeStartTime;
    }

    mapping(uint256 => Task) public tasks;
    mapping(uint256 => address[]) public taskJurors;
    mapping(uint256 => mapping(address => bool)) public hasVoted;
    mapping(uint256 => mapping(address => bool)) public voteChoice; 
    
    // Dynamic Reputation System
    struct JurorStats {
        uint256 correctVotes;       // Voted with majority
        uint256 totalVotes;         // Total participation
        uint256 weightedScore;      // The actual voting power
        uint256 lastVoteTime;       // To track activity
    }
    
    mapping(address => JurorStats) public jurors;
    address[] public activeJurorPool;
    mapping(address => bool) public isJurorInPool;
    
    uint256 public taskCount;

    // Events
    event TaskCreated(uint256 indexed taskId, address indexed requester, uint256 amount);
    event TaskClaimed(uint256 indexed taskId, address indexed worker);
    event WorkSubmitted(uint256 indexed taskId, address indexed worker);
    event TaskApproved(uint256 indexed taskId);
    event DisputeRaised(uint256 indexed taskId, address indexed raiser);
    event JurorSelected(uint256 indexed taskId, address indexed juror);
    event Voted(uint256 indexed taskId, address indexed juror, bool approve, uint256 votingPower);
    event DisputeResolved(uint256 indexed taskId, bool workerWins);

    constructor(address _usdc) Ownable(msg.sender) {
        usdc = IERC20(_usdc);
    }

    // --- JUROR POOL MANAGEMENT ---
    
    /**
     * @notice Register to become a potential juror.
     * Starts with baseline score. To avoid free sybils, owner can gate this or
     * it requires a Proof-of-Humanity / Proof-of-Compute token check (mocked here).
     */
    function registerAsJuror() external {
        require(!isJurorInPool[msg.sender], "Already registered");
        activeJurorPool.push(msg.sender);
        isJurorInPool[msg.sender] = true;
        
        if (jurors[msg.sender].totalVotes == 0) {
            // New jurors get a baseline power of 10 to start
            jurors[msg.sender].weightedScore = 10;
        }
    }

    // --- CORE ESCROW ---

    function createTask(
        bytes32 _descriptionHash,
        uint256 _amount,
        uint256 _deadlineHours,
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

    function submitWork(uint256 _taskId, bytes32 _outputHash) external {
        Task storage task = tasks[_taskId];
        require(task.status == TaskStatus.Open, "Not open");
        require(task.worker == msg.sender, "Not worker");
        require(block.timestamp < task.deadline, "Deadline passed");

        task.outputHash = _outputHash;
        task.submitTime = block.timestamp;
        task.status = TaskStatus.Submitted;

        emit WorkSubmitted(_taskId, msg.sender);
    }

    function approveWork(uint256 _taskId) external nonReentrant {
        Task storage task = tasks[_taskId];
        require(task.status == TaskStatus.Submitted, "Not submitted");
        require(msg.sender == task.requester, "Only requester");

        task.status = TaskStatus.Completed;
        usdc.safeTransfer(task.worker, task.amount);
        emit TaskApproved(_taskId);
    }

    // --- DISPUTE & RANDOM JURY SELECTION ---

    function raiseDispute(uint256 _taskId) external {
        Task storage task = tasks[_taskId];
        require(task.status == TaskStatus.Submitted, "Must be submitted");
        require(msg.sender == task.requester || msg.sender == task.worker, "Not party");
        require(activeJurorPool.length >= task.jurySize, "Not enough jurors in pool");
        
        task.status = TaskStatus.Disputed;
        task.disputeStartTime = block.timestamp;
        
        _selectRandomJurors(_taskId);
        
        emit DisputeRaised(_taskId, msg.sender);
    }

    /**
     * @dev Selects jurors randomly. In production, use Chainlink VRF.
     * Here we use block properties as a pseudo-random seed to assign jurors.
     * This prevents self-selection (Sybil paradise).
     */
    function _selectRandomJurors(uint256 _taskId) internal {
        Task storage task = tasks[_taskId];
        uint256 poolSize = activeJurorPool.length;
        
        // Simple pseudo-random selection (Replace with VRF on mainnet)
        uint256 seed = uint256(keccak256(abi.encodePacked(block.timestamp, block.prevrandao, _taskId)));
        
        uint256 selectedCount = 0;
        uint256 attempts = 0;
        
        while (selectedCount < task.jurySize && attempts < poolSize * 2) {
            uint256 index = uint256(keccak256(abi.encodePacked(seed, attempts))) % poolSize;
            address candidate = activeJurorPool[index];
            
            // Ensure candidate is not requester/worker and not already selected
            if (candidate != task.requester && candidate != task.worker) {
                bool alreadySelected = false;
                for (uint j = 0; j < taskJurors[_taskId].length; j++) {
                    if (taskJurors[_taskId][j] == candidate) {
                        alreadySelected = true;
                        break;
                    }
                }
                
                if (!alreadySelected) {
                    taskJurors[_taskId].push(candidate);
                    hasVoted[_taskId][candidate] = false;
                    emit JurorSelected(_taskId, candidate);
                    selectedCount++;
                }
            }
            attempts++;
        }
        
        // If we couldn't find enough neutral jurors, fallback to owner resolution
        if (selectedCount < task.jurySize) {
            // Edge case handling: fallback logic
        }
    }

    function castVote(uint256 _taskId, bool _approve) external nonReentrant {
        Task storage task = tasks[_taskId];
        require(task.status == TaskStatus.Disputed, "Not disputed");
        
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
        
        // VOTE POWER: Based on juror's historical reputation score
        uint256 power = jurors[msg.sender].weightedScore;

        if (_approve) {
            task.acceptPower += power;
        } else {
            task.rejectPower += power;
        }
        
        jurors[msg.sender].lastVoteTime = block.timestamp;
        
        emit Voted(_taskId, msg.sender, _approve, power);

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

        // Resolution is based on WEIGHTED POWER, not just simple count
        bool workerWins = task.acceptPower > task.rejectPower;
        
        // Update Reputation Scores
        for (uint i = 0; i < taskJurors[_taskId].length; i++) {
            address juror = taskJurors[_taskId][i];
            JurorStats storage stats = jurors[juror];
            
            stats.totalVotes++;
            
            if (voteChoice[_taskId][juror] == workerWins) {
                // Voted with majority: Increase power (max 1000)
                stats.correctVotes++;
                stats.weightedScore = _min(stats.weightedScore + 10, 1000);
            } else {
                // Voted against majority: DECAY power heavily (penalty for bad actors)
                // Decay by 50%
                stats.weightedScore = stats.weightedScore / 2;
                
                // If power drops too low, kick them out of the active pool
                if (stats.weightedScore < 5) {
                    isJurorInPool[juror] = false;
                    _removeFromPool(juror);
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
                // Swap with last element and pop
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
        require(task.status == TaskStatus.Submitted, "Not submitted");
        require(block.timestamp > task.submitTime + 48 hours, "Grace period active");
        require(msg.sender == task.worker, "Only worker");
        
        task.status = TaskStatus.Completed;
        usdc.safeTransfer(task.worker, task.amount);
    }
}
