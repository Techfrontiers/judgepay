// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title JudgePayEscrow (V3 - Trustless with Jury Incentives)
 * @notice Conditional USDC execution for AI agents with staking, random jury, and positive incentives
 */
contract JudgePayEscrow is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdc;

    enum TaskStatus {
        Open,           // Waiting for worker
        Submitted,      // Work submitted, pending evaluation
        Completed,      // Conditions met, USDC released
        Refunded,       // Conditions failed or timeout, USDC returned
        Disputed,       // Under multi-agent review (Jury)
        Resolved        // Dispute settled by Jury
    }

    struct Task {
        address requester;          
        address worker;             
        uint256 amount;             // Task budget
        uint256 workerStake;        // Required stake from worker
        uint256 disputeFee;         // Fee paid by the loser of the dispute to reward jurors
        uint256 createdAt;          
        uint256 deadline;           
        uint256 submitTime;         
        bytes32 descriptionHash;    
        bytes32 outputHash;         
        TaskStatus status;          
        uint256 minLength;          
        uint256 maxLength;          
        
        // Jury System
        uint256 jurySize;           // Number of jurors needed (e.g., 3 or 5)
        uint256 jurorStake;         // Small anti-spam stake required per juror (can be 0)
        uint256 acceptVotes;        // Votes to approve
        uint256 rejectVotes;        // Votes to reject
        uint256 disputeStartTime;
    }

    mapping(uint256 => Task) public tasks;
    mapping(uint256 => address[]) public taskJurors;
    mapping(uint256 => mapping(address => bool)) public hasVoted;
    mapping(uint256 => mapping(address => bool)) public voteChoice; // true = accept, false = reject
    
    uint256 public taskCount;

    // Events
    event TaskCreated(uint256 indexed taskId, address indexed requester, uint256 amount, uint256 workerStake, uint256 disputeFee, uint256 deadline);
    event TaskClaimed(uint256 indexed taskId, address indexed worker);
    event WorkSubmitted(uint256 indexed taskId, address indexed worker, bytes32 outputHash);
    event TaskApproved(uint256 indexed taskId);
    event DisputeRaised(uint256 indexed taskId, address indexed raiser);
    event JurorJoined(uint256 indexed taskId, address indexed juror);
    event Voted(uint256 indexed taskId, address indexed juror, bool approve);
    event DisputeResolved(uint256 indexed taskId, bool approved);

    constructor(address _usdc) Ownable(msg.sender) {
        usdc = IERC20(_usdc);
    }

    function createTask(
        bytes32 _descriptionHash,
        uint256 _amount,
        uint256 _workerStake,
        uint256 _disputeFee,
        uint256 _deadlineHours,
        uint256 _minLength,
        uint256 _maxLength,
        uint256 _jurySize,
        uint256 _jurorStake
    ) external nonReentrant returns (uint256) {
        require(_amount > 0, "Amount must be > 0");
        require(_deadlineHours > 0, "Deadline must be > 0");
        require(_jurySize % 2 == 1, "Jury size must be odd");
        
        // The requester must pre-fund the task amount AND their potential side of the dispute fee
        usdc.safeTransferFrom(msg.sender, address(this), _amount + _disputeFee);

        uint256 taskId = taskCount++;
        
        tasks[taskId] = Task({
            requester: msg.sender,
            worker: address(0),
            amount: _amount,
            workerStake: _workerStake,
            disputeFee: _disputeFee,
            createdAt: block.timestamp,
            deadline: block.timestamp + (_deadlineHours * 1 hours),
            submitTime: 0,
            descriptionHash: _descriptionHash,
            outputHash: bytes32(0),
            status: TaskStatus.Open,
            minLength: _minLength,
            maxLength: _maxLength,
            jurySize: _jurySize,
            jurorStake: _jurorStake, // Can be set to 0 for free voting
            acceptVotes: 0,
            rejectVotes: 0,
            disputeStartTime: 0
        });

        emit TaskCreated(taskId, msg.sender, _amount, _workerStake, _disputeFee, tasks[taskId].deadline);
        return taskId;
    }

    function claimTask(uint256 _taskId) external nonReentrant {
        Task storage task = tasks[_taskId];
        require(task.status == TaskStatus.Open, "Not open");
        require(task.worker == address(0), "Already claimed");
        require(block.timestamp < task.deadline, "Expired");
        require(msg.sender != task.requester, "Requester cannot claim");

        // Worker must stake their side of the dispute fee AND the performance stake
        uint256 totalWorkerRequired = task.workerStake + task.disputeFee;
        if (totalWorkerRequired > 0) {
            usdc.safeTransferFrom(msg.sender, address(this), totalWorkerRequired);
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

        emit WorkSubmitted(_taskId, msg.sender, _outputHash);
    }

    function approveWork(uint256 _taskId) external nonReentrant {
        Task storage task = tasks[_taskId];
        require(task.status == TaskStatus.Submitted, "Not submitted");
        require(msg.sender == task.requester, "Only requester");

        task.status = TaskStatus.Completed;
        
        // Happy path: Worker gets Task Amount + Their Stake + Their Dispute Fee back
        uint256 workerPayout = task.amount + task.workerStake + task.disputeFee;
        usdc.safeTransfer(task.worker, workerPayout);

        // Requester gets their Dispute Fee back
        usdc.safeTransfer(task.requester, task.disputeFee);
        
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

        // Small anti-spam stake (can be configured to 0 by requester)
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
        
        // Slashing pool comes from minority voters + the loser's dispute fee
        uint256 slashPool = task.disputeFee; 
        
        for (uint i = 0; i < taskJurors[_taskId].length; i++) {
            address juror = taskJurors[_taskId][i];
            if (voteChoice[_taskId][juror] != workerWins) {
                // Minority voter -> Slashed
                slashPool += task.jurorStake;
            }
        }

        uint256 majorityCount = workerWins ? task.acceptVotes : task.rejectVotes;
        uint256 jurorReward = 0;
        if (majorityCount > 0) {
            jurorReward = slashPool / majorityCount;
        }

        for (uint i = 0; i < taskJurors[_taskId].length; i++) {
            address juror = taskJurors[_taskId][i];
            if (voteChoice[_taskId][juror] == workerWins) {
                // Majority voter -> Gets their stake back + Reward (from loser's fee and slashed jurors)
                usdc.safeTransfer(juror, task.jurorStake + jurorReward);
            }
        }

        // 3. Payout to Parties
        if (workerWins) {
            // Worker wins: Gets Task Amount + Worker Stake + Their Dispute Fee back
            usdc.safeTransfer(task.worker, task.amount + task.workerStake + task.disputeFee);
        } else {
            // Requester wins: Gets Task Amount + Their Dispute Fee + Worker's Performance Stake back
            usdc.safeTransfer(task.requester, task.amount + task.disputeFee + task.workerStake);
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
        usdc.safeTransfer(task.requester, task.amount + task.disputeFee);
    }

    function claimTimeoutAfterSubmit(uint256 _taskId) external nonReentrant {
        Task storage task = tasks[_taskId];
        require(task.status == TaskStatus.Submitted, "Not submitted");
        require(block.timestamp > task.submitTime + 48 hours, "Grace period active");
        require(msg.sender == task.worker, "Only worker");
        
        task.status = TaskStatus.Completed;
        // Worker gets everything if requester abandons
        usdc.safeTransfer(task.worker, task.amount + task.workerStake + task.disputeFee);
        // Requester gets their dispute fee back
        usdc.safeTransfer(task.requester, task.disputeFee);
    }
}
