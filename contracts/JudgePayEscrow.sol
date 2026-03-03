// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title JudgePayEscrow (V5 - Reputation Based Jury, Zero-Cost Evaluators)
 * @notice Conditional USDC execution focusing purely on escrow and reputation-based dispute resolution.
 * @dev The contract acts ONLY as a neutral vault. Jurors vote based on off-chain reputation (Karma/Credit Score) without staking money.
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
        uint256 amount;             // Pure task budget, no hidden fees
        uint256 createdAt;          
        uint256 deadline;           
        uint256 submitTime;         
        bytes32 descriptionHash;    
        bytes32 outputHash;         
        TaskStatus status;          
        
        // Zero-Cost Reputation Jury System
        uint256 jurySize;           
        uint256 acceptVotes;        
        uint256 rejectVotes;        
        uint256 disputeStartTime;
    }

    // Task ID => Task
    mapping(uint256 => Task) public tasks;
    
    // Task ID => Juror Addresses
    mapping(uint256 => address[]) public taskJurors;
    
    // Task ID => Juror => Has Voted
    mapping(uint256 => mapping(address => bool)) public hasVoted;
    
    // Task ID => Juror => Vote Choice (true = accept worker's output)
    mapping(uint256 => mapping(address => bool)) public voteChoice; 
    
    // Global Reputation Tracking (Credit Score for Jurors)
    // Tracks how many times a juror voted with the majority
    mapping(address => uint256) public successfulResolutions;
    // Tracks total times a juror participated
    mapping(address => uint256) public totalParticipations;
    
    uint256 public taskCount;

    // Events
    event TaskCreated(uint256 indexed taskId, address indexed requester, uint256 amount);
    event TaskClaimed(uint256 indexed taskId, address indexed worker);
    event WorkSubmitted(uint256 indexed taskId, address indexed worker);
    event TaskApproved(uint256 indexed taskId);
    event DisputeRaised(uint256 indexed taskId, address indexed raiser);
    event JurorJoined(uint256 indexed taskId, address indexed juror);
    event Voted(uint256 indexed taskId, address indexed juror, bool approve);
    event DisputeResolved(uint256 indexed taskId, bool workerWins);

    // To prevent sybil attacks without money, we can optionally whitelist jurors
    // Or require a minimum global reputation score to join certain high-value tasks
    mapping(address => bool) public approvedJurors;
    bool public requireWhitelist = false;

    constructor(address _usdc) Ownable(msg.sender) {
        usdc = IERC20(_usdc);
    }

    function toggleWhitelistRequirement(bool _require) external onlyOwner {
        requireWhitelist = _require;
    }

    function whitelistJuror(address _juror, bool _approved) external onlyOwner {
        approvedJurors[_juror] = _approved;
    }

    function createTask(
        bytes32 _descriptionHash,
        uint256 _amount,
        uint256 _deadlineHours,
        uint256 _jurySize
    ) external nonReentrant returns (uint256) {
        require(_amount > 0, "Amount must be > 0");
        require(_deadlineHours > 0, "Deadline must be > 0");
        require(_jurySize % 2 == 1, "Jury size must be odd");
        
        // Pure Escrow: Requester locks ONLY the task amount. No fees, no gas subsidies.
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
            acceptVotes: 0,
            rejectVotes: 0,
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

        // Worker claims for FREE. No staking required.
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
        
        // 100% of escrow goes to worker. The protocol takes NOTHING.
        usdc.safeTransfer(task.worker, task.amount);
        emit TaskApproved(_taskId);
    }

    function raiseDispute(uint256 _taskId) external {
        Task storage task = tasks[_taskId];
        require(task.status == TaskStatus.Submitted, "Must be submitted");
        require(msg.sender == task.requester || msg.sender == task.worker, "Not party");
        
        task.status = TaskStatus.Disputed;
        task.disputeStartTime = block.timestamp;
        emit DisputeRaised(_taskId, msg.sender);
    }

    function joinJury(uint256 _taskId) external {
        Task storage task = tasks[_taskId];
        require(task.status == TaskStatus.Disputed, "Not disputed");
        require(msg.sender != task.requester && msg.sender != task.worker, "Parties cannot be jurors");
        require(taskJurors[_taskId].length < task.jurySize, "Jury full");
        require(!hasVoted[_taskId][msg.sender], "Already in jury");
        
        if (requireWhitelist) {
            require(approvedJurors[msg.sender], "Juror not whitelisted");
        }

        // NO MONEY REQUIRED. Jurors join purely to build their reputation score.
        taskJurors[_taskId].push(msg.sender);
        hasVoted[_taskId][msg.sender] = false; 
        
        emit JurorJoined(_taskId, msg.sender);
    }

    function castVote(uint256 _taskId, bool _approve) external nonReentrant {
        Task storage task = tasks[_taskId];
        require(task.status == TaskStatus.Disputed, "Not disputed");
        
        bool isJuror = false;
        for (uint i = 0; i < taskJurors[_taskId].length; i++) {
            if (taskJurors[_taskId][i] == msg.sender) {
                isJuror = true;
                break;
            }
        }
        require(isJuror, "Not a juror");
        require(!hasVoted[_taskId][msg.sender], "Already voted");

        hasVoted[_taskId][msg.sender] = true;
        voteChoice[_taskId][msg.sender] = _approve;

        if (_approve) {
            task.acceptVotes++;
        } else {
            task.rejectVotes++;
        }

        emit Voted(_taskId, msg.sender, _approve);

        if (task.acceptVotes + task.rejectVotes == task.jurySize) {
            _resolveDispute(_taskId);
        }
    }

    function _resolveDispute(uint256 _taskId) internal {
        Task storage task = tasks[_taskId];
        task.status = TaskStatus.Resolved;

        bool workerWins = task.acceptVotes > task.rejectVotes;
        
        // 1. Update Reputation Scores (Credit Score) instead of exchanging money
        for (uint i = 0; i < taskJurors[_taskId].length; i++) {
            address juror = taskJurors[_taskId][i];
            totalParticipations[juror]++;
            
            if (voteChoice[_taskId][juror] == workerWins) {
                // Voted with majority -> Gain Reputation
                successfulResolutions[juror]++;
            }
            // If they voted against majority, their success rate drops (total goes up, success stays same)
        }

        // 2. Pure Escrow Resolution (No fees taken, 100% routing)
        if (workerWins) {
            // Worker wins: Gets the full task amount
            usdc.safeTransfer(task.worker, task.amount);
        } else {
            // Requester wins: Gets their full task amount back
            usdc.safeTransfer(task.requester, task.amount);
        }

        emit DisputeResolved(_taskId, workerWins);
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
    
    // View function to check a juror's reputation score (Success Rate)
    function getJurorReputation(address _juror) external view returns (uint256 successCount, uint256 totalCount) {
        return (successfulResolutions[_juror], totalParticipations[_juror]);
    }
}
