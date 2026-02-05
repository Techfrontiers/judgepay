// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../contracts/JudgePayLite.sol";

contract DeployJudgePayLite is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        // Base Sepolia USDC: 0x036CbD53842c5426634e7929541eC2318f3dCF7e
        address usdcAddress = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
        
        vm.startBroadcast(deployerPrivateKey);
        new JudgePayLite(usdcAddress);
        vm.stopBroadcast();
    }
}
