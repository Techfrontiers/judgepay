// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title JudgePayEscrow
 * @notice Conditional USDC execution for AI agents
 * @dev Escrow with automated condition checking and multi-agent evaluation
 */
contract JudgePayEscrow is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    // USDC on Base Sepolia
    IERC20 public immutable usdc;

    enum TaskStatus {
        Open,           // Waiting for worker
        Submitted,      // Work submitted, pending evaluation
        Completed,      // Conditions met, USDC released
        Refunded,       // Conditions failed or timeout, USDC returned
        Disputed        // Under multi-agent review
    }

    struct Task {
        address requester;          // Who created the task
        address worker;             // Who claimed the task
        address evaluator;          // Who evaluates (address(0) = auto)
        uint256 amount;             // USDC amount in escrow
        uint256 createdAt;          // Task creation timestamp
        uint256 deadline;           // Deadline timestamp
        bytes32 descriptionHash;    // Hash of task description
        bytes32 outputHash;         // Hash of submitted output
        TaskStatus status;          // Current status
        uint256 minLength;          // Minimum output length
        uint256 maxLength;          // Maximum output length
        uint8 requiredApprovals;    // For multi-sig (0 = single evaluator)
        uint8 currentApprovals;     // Current approval count
    }

    // Task ID => Task
    mapping(uint256 => Task) public tasks;
    
    // Task ID => Evaluator => Has Approved
    mapping(uint256 => mapping(address => bool)) public approvals;
    
    // Task counter
    uint256 public taskCount;

    // Events
    event TaskCreated(
        uint256 indexed taskId,
        address indexed requester,
        uint256 amount,
        uint256 deadline
    );
    
    event TaskClaimed(
        uint256 indexed taskId,
        address indexed worker
    );
    
    event WorkSubmitted(
        uint256 indexed taskId,
        address indexed worker,
        bytes32 outputHash
    );
    
    event TaskEvaluated(
        uint256 indexed taskId,
        address indexed evaluator,
        bool passed
    );
    
    event TaskCompleted(
        uint256 indexed taskId,
        address indexed worker,
        uint256 amount
    );
    
    event TaskRefunded(
        uint256 indexed taskId,
        address indexed requester,
        uint256 amount
    );
    
    event DisputeRaised(
        uint256 indexed taskId,
        address indexed raiser
    );

    constructor(address _usdc) Ownable(msg.sender) {
        usdc = IERC20(_usdc);
    }

    /**
     * @notice Create a new task with USDC escrow
     * @param _descriptionHash Hash of task description (stored off-chain)
     * @param _amount USDC amount to escrow
     * @param _deadlineHours Hours until deadline
     * @param _evaluator Address of evaluator (address(0) for auto)
     * @param _minLength Minimum output length (0 = no limit)
     * @param _maxLength Maximum output length (0 = no limit)
     * @param _requiredApprovals Number of approvals needed (0 = single)
     */
    function createTask(
        bytes32 _descriptionHash,
        uint256 _amount,
        uint256 _deadlineHours,
        address _evaluator,
        uint256 _minLength,
        uint256 _maxLength,
        uint8 _requiredApprovals
    ) external nonReentrant returns (uint256) {
        require(_amount > 0, "Amount must be > 0");
        require(_deadlineHours > 0, "Deadline must be > 0");

        // Transfer USDC to escrow
        usdc.safeTransferFrom(msg.sender, address(this), _amount);

        uint256 taskId = taskCount++;
        
        tasks[taskId] = Task({
            requester: msg.sender,
            worker: address(0),
            evaluator: _evaluator,
            amount: _amount,
            createdAt: block.timestamp,
            deadline: block.timestamp + (_deadlineHours * 1 hours),
            descriptionHash: _descriptionHash,
            outputHash: bytes32(0),
            status: TaskStatus.Open,
            minLength: _minLength,
            maxLength: _maxLength,
            requiredApprovals: _requiredApprovals,
            currentApprovals: 0
        });

        emit TaskCreated(taskId, msg.sender, _amount, tasks[taskId].deadline);
        
        return taskId;
    }

    /**
     * @notice Claim an open task as worker
     * @param _taskId Task ID to claim
     */
    function claimTask(uint256 _taskId) external {
        Task storage task = tasks[_taskId];
        
        require(task.status == TaskStatus.Open, "Task not open");
        require(block.timestamp < task.deadline, "Task expired");
        require(msg.sender != task.requester, "Requester cannot claim");

        task.worker = msg.sender;

        emit TaskClaimed(_taskId, msg.sender);
    }

    /**
     * @notice Submit work for a claimed task
     * @param _taskId Task ID
     * @param _outputHash Hash of the output
     * @param _outputLength Actual length of output (for on-chain validation)
     */
    function submitWork(
        uint256 _taskId,
        bytes32 _outputHash,
        uint256 _outputLength
    ) external {
        Task storage task = tasks[_taskId];
        
        require(task.status == TaskStatus.Open, "Task not open");
        require(task.worker == msg.sender, "Not the worker");
        require(block.timestamp < task.deadline, "Deadline passed");

        // Check length conditions on-chain
        if (task.minLength > 0) {
            require(_outputLength >= task.minLength, "Output too short");
        }
        if (task.maxLength > 0) {
            require(_outputLength <= task.maxLength, "Output too long");
        }

        task.outputHash = _outputHash;
        task.status = TaskStatus.Submitted;

        emit WorkSubmitted(_taskId, msg.sender, _outputHash);

        // If no evaluator required, auto-complete
        if (task.evaluator == address(0) && task.requiredApprovals == 0) {
            _completeTask(_taskId);
        }
    }

    /**
     * @notice Evaluate submitted work
     * @param _taskId Task ID
     * @param _approve Whether to approve the work
     */
    function evaluate(uint256 _taskId, bool _approve) external {
        Task storage task = tasks[_taskId];
        
        require(task.status == TaskStatus.Submitted, "Not submitted");
        
        // Check evaluator permission
        if (task.evaluator != address(0)) {
            require(msg.sender == task.evaluator, "Not authorized evaluator");
        }

        emit TaskEvaluated(_taskId, msg.sender, _approve);

        if (_approve) {
            if (task.requiredApprovals > 0) {
                // Multi-sig mode
                require(!approvals[_taskId][msg.sender], "Already approved");
                approvals[_taskId][msg.sender] = true;
                task.currentApprovals++;

                if (task.currentApprovals >= task.requiredApprovals) {
                    _completeTask(_taskId);
                }
            } else {
                // Single evaluator mode
                _completeTask(_taskId);
            }
        } else {
            _refundTask(_taskId);
        }
    }

    /**
     * @notice Raise a dispute (triggers multi-agent review)
     * @param _taskId Task ID
     */
    function raiseDispute(uint256 _taskId) external {
        Task storage task = tasks[_taskId];
        
        require(
            task.status == TaskStatus.Submitted,
            "Can only dispute submitted work"
        );
        require(
            msg.sender == task.requester || msg.sender == task.worker,
            "Not party to task"
        );

        task.status = TaskStatus.Disputed;

        emit DisputeRaised(_taskId, msg.sender);
    }

    /**
     * @notice Claim refund if deadline passed without submission
     * @param _taskId Task ID
     */
    function claimTimeout(uint256 _taskId) external {
        Task storage task = tasks[_taskId];
        
        require(task.status == TaskStatus.Open, "Task not open");
        require(block.timestamp > task.deadline, "Deadline not passed");
        require(msg.sender == task.requester, "Not requester");

        _refundTask(_taskId);
    }

    /**
     * @dev Internal: Complete task and release USDC to worker
     */
    function _completeTask(uint256 _taskId) internal {
        Task storage task = tasks[_taskId];
        
        task.status = TaskStatus.Completed;
        usdc.safeTransfer(task.worker, task.amount);

        emit TaskCompleted(_taskId, task.worker, task.amount);
    }

    /**
     * @dev Internal: Refund task and return USDC to requester
     */
    function _refundTask(uint256 _taskId) internal {
        Task storage task = tasks[_taskId];
        
        task.status = TaskStatus.Refunded;
        usdc.safeTransfer(task.requester, task.amount);

        emit TaskRefunded(_taskId, task.requester, task.amount);
    }

    /**
     * @notice Get task details
     * @param _taskId Task ID
     */
    function getTask(uint256 _taskId) external view returns (Task memory) {
        return tasks[_taskId];
    }

    /**
     * @notice Check if address has approved a task
     * @param _taskId Task ID
     * @param _evaluator Evaluator address
     */
    function hasApproved(uint256 _taskId, address _evaluator) external view returns (bool) {
        return approvals[_taskId][_evaluator];
    }
}
