// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title JudgePayEscrow (V4 - Dynamic Gas Subsidized Jury)
 * @notice Conditional USDC execution for AI agents with gas-conscious jury economics
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
        uint256 workerStake;        
        uint256 disputeFee;         // The bounty paid by the loser to the jurors
        uint256 gasSubsidy;         // Extra fee paid upfront by both to cover juror gas costs
        uint256 createdAt;          
        uint256 deadline;           
        uint256 submitTime;         
        bytes32 descriptionHash;    
        bytes32 outputHash;         
        TaskStatus status;          
        uint256 minLength;          
        uint256 maxLength;          
        
        // Jury System
        uint256 jurySize;           
        uint256 jurorStake;         // Must be >= disputeFee / jurySize to prevent Sybil
        uint256 acceptVotes;        
        uint256 rejectVotes;        
        uint256 disputeStartTime;
    }

    mapping(uint256 => Task) public tasks;
    mapping(uint256 => address[]) public taskJurors;
    mapping(uint256 => mapping(address => bool)) public hasVoted;
    mapping(uint256 => mapping(address => bool)) public voteChoice; 
    
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

    constructor(address _usdc) Ownable(msg.sender) {
        usdc = IERC20(_usdc);
    }

    function createTask(
        bytes32 _descriptionHash,
        uint256 _amount,
        uint256 _workerStake,
        uint256 _disputeFee,
        uint256 _gasSubsidy,
        uint256 _deadlineHours,
        uint256 _minLength,
        uint256 _maxLength,
        uint256 _jurySize,
        uint256 _jurorStake
    ) external nonReentrant returns (uint256) {
        require(_amount > 0, "Amount must be > 0");
        require(_disputeFee >= 5 * 10**6, "Dispute fee must be at least 5 USDC");
        require(_deadlineHours > 0, "Deadline must be > 0");
        require(_jurySize % 2 == 1, "Jury size must be odd");
        
        // Requester locks: Task Amount + Their side of Dispute Fee + Gas Subsidy for Jurors
        uint256 totalRequesterDeposit = _amount + _disputeFee + _gasSubsidy;
        usdc.safeTransferFrom(msg.sender, address(this), totalRequesterDeposit);

        uint256 taskId = taskCount++;
        
        tasks[taskId] = Task({
            requester: msg.sender,
            worker: address(0),
            amount: _amount,
            workerStake: _workerStake,
            disputeFee: _disputeFee,
            gasSubsidy: _gasSubsidy,
            createdAt: block.timestamp,
            deadline: block.timestamp + (_deadlineHours * 1 hours),
            submitTime: 0,
            descriptionHash: _descriptionHash,
            outputHash: bytes32(0),
            status: TaskStatus.Open,
            minLength: _minLength,
            maxLength: _maxLength,
            jurySize: _jurySize,
            jurorStake: _jurorStake, 
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

        // Worker locks: Performance Stake + Their side of Dispute Fee + Gas Subsidy for Jurors
        uint256 totalWorkerDeposit = task.workerStake + task.disputeFee + task.gasSubsidy;
        if (totalWorkerDeposit > 0) {
            usdc.safeTransferFrom(msg.sender, address(this), totalWorkerDeposit);
        }

        task.worker = msg.sender;
        emit TaskClaimed(_taskId, msg.sender);
    }

    function submitWork(uint256 _taskId, bytes32 _outputHash, uint256 _outputLength) external {
        Task storage task = tasks[_taskId];
        require(task.status == TaskStatus.Open, "Not open");
        require(task.worker == msg.sender, "Not worker");
        require(block.timestamp < task.deadline, "Deadline passed");

        if (task.minLength > 0) require(_outputLength >= task.minLength, "Too short");
        if (task.maxLength > 0) require(_outputLength <= task.maxLength, "Too long");

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
        
        // Happy path: No dispute happened.
        // Worker gets: Task Amount + Worker Stake + Dispute Fee + Gas Subsidy (Full refund of deposits)
        uint256 workerPayout = task.amount + task.workerStake + task.disputeFee + task.gasSubsidy;
        usdc.safeTransfer(task.worker, workerPayout);

        // Requester gets: Dispute Fee + Gas Subsidy back (Full refund of deposits)
        uint256 requesterRefund = task.disputeFee + task.gasSubsidy;
        usdc.safeTransfer(task.requester, requesterRefund);
        
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

    function joinJury(uint256 _taskId) external nonReentrant {
        Task storage task = tasks[_taskId];
        require(task.status == TaskStatus.Disputed, "Not disputed");
        require(msg.sender != task.requester && msg.sender != task.worker, "Parties cannot be jurors");
        require(taskJurors[_taskId].length < task.jurySize, "Jury full");
        require(!hasVoted[_taskId][msg.sender], "Already in jury");

        if (task.jurorStake > 0) {
            usdc.safeTransferFrom(msg.sender, address(this), task.jurorStake);
        }

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
        
        // The reward pool for jurors consists of:
        // 1. The loser's dispute fee
        // 2. Both parties' gas subsidies (to cover juror transaction costs)
        uint256 jurorRewardPool = task.disputeFee + (task.gasSubsidy * 2); 
        
        for (uint i = 0; i < taskJurors[_taskId].length; i++) {
            address juror = taskJurors[_taskId][i];
            if (voteChoice[_taskId][juror] != workerWins) {
                // Minority voter -> Slashed! Their stake is added to the reward pool
                jurorRewardPool += task.jurorStake;
            }
        }

        uint256 majorityCount = workerWins ? task.acceptVotes : task.rejectVotes;
        uint256 payoutPerWinningJuror = 0;
        if (majorityCount > 0) {
            payoutPerWinningJuror = jurorRewardPool / majorityCount;
        }

        for (uint i = 0; i < taskJurors[_taskId].length; i++) {
            address juror = taskJurors[_taskId][i];
            if (voteChoice[_taskId][juror] == workerWins) {
                // Majority voter -> Gets their stake back + their share of the reward pool
                usdc.safeTransfer(juror, task.jurorStake + payoutPerWinningJuror);
            }
        }

        // Payout to Winning Party
        if (workerWins) {
            // Worker wins: Gets Task Amount + Worker Stake + Their Dispute Fee back
            // (Their Gas Subsidy was spent to pay the jurors)
            usdc.safeTransfer(task.worker, task.amount + task.workerStake + task.disputeFee);
        } else {
            // Requester wins: Gets Task Amount + Their Dispute Fee + Worker's Performance Stake back
            // (Their Gas Subsidy was spent to pay the jurors)
            usdc.safeTransfer(task.requester, task.amount + task.disputeFee + task.workerStake);
        }

        emit DisputeResolved(_taskId, workerWins);
    }
    
    function claimTimeout(uint256 _taskId) external nonReentrant {
        Task storage task = tasks[_taskId];
        require(task.status == TaskStatus.Open, "Not open");
        require(block.timestamp > task.deadline, "Not expired");
        require(msg.sender == task.requester, "Not requester");

        task.status = TaskStatus.Refunded;
        usdc.safeTransfer(task.requester, task.amount + task.disputeFee + task.gasSubsidy);
    }

    function claimTimeoutAfterSubmit(uint256 _taskId) external nonReentrant {
        Task storage task = tasks[_taskId];
        require(task.status == TaskStatus.Submitted, "Not submitted");
        require(block.timestamp > task.submitTime + 48 hours, "Grace period active");
        require(msg.sender == task.worker, "Only worker");
        
        task.status = TaskStatus.Completed;
        // Worker gets everything if requester abandons
        usdc.safeTransfer(task.worker, task.amount + task.workerStake + task.disputeFee + task.gasSubsidy);
        // Requester gets their dispute fee back
        usdc.safeTransfer(task.requester, task.disputeFee + task.gasSubsidy);
    }
}
