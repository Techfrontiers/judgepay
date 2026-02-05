// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title JudgePayLite
 * @notice Minimal conditional USDC escrow for AI agents (gas-optimized)
 */
interface IERC20 {
    function transferFrom(address, address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

contract JudgePayLite {
    IERC20 public immutable usdc;
    
    enum Status { Open, Submitted, Completed, Refunded }
    
    struct Task {
        address requester;
        address worker;
        uint96 amount;
        uint40 deadline;
        Status status;
    }
    
    mapping(uint256 => Task) public tasks;
    uint256 public taskCount;
    
    event TaskCreated(uint256 indexed id, address indexed requester, uint96 amount);
    event WorkSubmitted(uint256 indexed id, address indexed worker);
    event TaskCompleted(uint256 indexed id, uint96 amount);
    event TaskRefunded(uint256 indexed id, uint96 amount);
    
    constructor(address _usdc) {
        usdc = IERC20(_usdc);
    }
    
    function createTask(uint96 _amount, uint40 _deadlineHours) external returns (uint256) {
        require(_amount > 0, "Amount=0");
        require(usdc.transferFrom(msg.sender, address(this), _amount), "Transfer failed");
        
        uint256 id = taskCount++;
        tasks[id] = Task({
            requester: msg.sender,
            worker: address(0),
            amount: _amount,
            deadline: uint40(block.timestamp + _deadlineHours * 1 hours),
            status: Status.Open
        });
        
        emit TaskCreated(id, msg.sender, _amount);
        return id;
    }
    
    function submitWork(uint256 _id) external {
        Task storage t = tasks[_id];
        require(t.status == Status.Open, "Not open");
        require(block.timestamp < t.deadline, "Expired");
        require(msg.sender != t.requester, "Requester!=worker");
        
        t.worker = msg.sender;
        t.status = Status.Submitted;
        emit WorkSubmitted(_id, msg.sender);
    }
    
    function approve(uint256 _id) external {
        Task storage t = tasks[_id];
        require(t.status == Status.Submitted, "Not submitted");
        require(msg.sender == t.requester, "Only requester");
        
        t.status = Status.Completed;
        require(usdc.transfer(t.worker, t.amount), "Transfer failed");
        emit TaskCompleted(_id, t.amount);
    }
    
    function reject(uint256 _id) external {
        Task storage t = tasks[_id];
        require(t.status == Status.Submitted, "Not submitted");
        require(msg.sender == t.requester, "Only requester");
        
        t.status = Status.Refunded;
        require(usdc.transfer(t.requester, t.amount), "Transfer failed");
        emit TaskRefunded(_id, t.amount);
    }
    
    function claimTimeout(uint256 _id) external {
        Task storage t = tasks[_id];
        require(t.status == Status.Open, "Not open");
        require(block.timestamp > t.deadline, "Not expired");
        require(msg.sender == t.requester, "Only requester");
        
        t.status = Status.Refunded;
        require(usdc.transfer(t.requester, t.amount), "Transfer failed");
        emit TaskRefunded(_id, t.amount);
    }
}
