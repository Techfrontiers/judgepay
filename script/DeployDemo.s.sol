// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {JudgePayLite} from "../contracts/JudgePayLite.sol";
import {MockUSDC} from "../contracts/MockUSDC.sol";

contract DeployDemo is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy MockUSDC
        MockUSDC usdc = new MockUSDC();
        console.log("MockUSDC Deployed at:", address(usdc));

        // 2. Deploy JudgePayLite (linked to MockUSDC)
        JudgePayLite judgePay = new JudgePayLite(address(usdc));
        console.log("JudgePayLite Deployed at:", address(judgePay));

        // 3. Setup Demo State (Optional)
        // Mint some more to deployer (already done in constructor)
        // Approve JudgePay to spend USDC
        usdc.approve(address(judgePay), 1000 * 10**6);
        console.log("Approved JudgePay to spend 1000 USDC");

        vm.stopBroadcast();
    }
}
