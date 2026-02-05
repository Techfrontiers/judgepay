// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/JudgePayLite.sol";

contract JudgePayLiteTest is Test {
    JudgePayLite public judgePay;
    address public owner = address(1);
    address public agent = address(2);
    address public recipient = address(3);
    uint256 public constant AMOUNT = 100 * 10**6; // 100 USDC (6 decimals)

    function setUp() public {
        vm.prank(owner);
        // Using a dummy address for USDC in tests
        judgePay = new JudgePayLite(address(0x123));
    }

    function test_CreateEscrow() public {
        vm.prank(owner);
        // Assuming JudgePayLite has a simple escrow creation for the hackathon
        // Let's check the contract source first.
    }
}
