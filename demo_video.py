#!/usr/bin/env python3
"""
🎬 JudgePay Demo Script
Run this to see the full flow with beautiful output
"""

import json
from web3 import Web3
import os
import time

# ═══════════════════════════════════════════════════════════════
# 🎨 CONFIGURATION
# ═══════════════════════════════════════════════════════════════

RPC_URL = "https://sepolia.base.org"
JUDGEPAY_ADDRESS = Web3.to_checksum_address("0x941bb35BFf8314A20c739EC129d6F38ba73BD4E5")
USDC_ADDRESS = Web3.to_checksum_address("0x036CbD53842c5426634e7929541eC2318f3dCF7e")
PRIVATE_KEY = os.environ.get("PRIVATE_KEY")
MY_ADDRESS = Web3.to_checksum_address("0x4a6a4Db15Ce7C892f62c750fDcC0D34d11572a99")

# ═══════════════════════════════════════════════════════════════
# 🎨 PRETTY PRINT
# ═══════════════════════════════════════════════════════════════

def banner():
    print("""
╔═══════════════════════════════════════════════════════════════╗
║  🏛️  J U D G E P A Y   D E M O                               ║
║  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━  ║
║  Financial Judgment for AI Agents                             ║
║  Built for OpenClaw USDC Hackathon on Moltbook                ║
╚═══════════════════════════════════════════════════════════════╝
    """)

def section(title):
    print(f"\n{'─'*60}")
    print(f"  {title}")
    print(f"{'─'*60}")

def success(msg):
    print(f"  ✅ {msg}")

def info(msg):
    print(f"  ℹ️  {msg}")

def money(msg):
    print(f"  💰 {msg}")

def tx_link(tx_hash):
    return f"https://sepolia.basescan.org/tx/{tx_hash}"

# ═══════════════════════════════════════════════════════════════
# 🔧 ABI
# ═══════════════════════════════════════════════════════════════

USDC_ABI = [
    {"inputs":[{"internalType":"address","name":"account","type":"address"}],"name":"balanceOf","outputs":[{"internalType":"uint256","name":"","type":"uint256"}],"stateMutability":"view","type":"function"},
    {"inputs":[{"internalType":"address","name":"spender","type":"address"},{"internalType":"uint256","name":"value","type":"uint256"}],"name":"approve","outputs":[{"internalType":"bool","name":"","type":"bool"}],"stateMutability":"nonpayable","type":"function"}
]

JUDGEPAY_ABI = [
    {"inputs":[{"internalType":"uint96","name":"_amount","type":"uint96"},{"internalType":"uint40","name":"_deadlineHours","type":"uint40"}],"name":"createTask","outputs":[{"internalType":"uint256","name":"","type":"uint256"}],"stateMutability":"nonpayable","type":"function"},
    {"inputs":[{"internalType":"uint256","name":"_id","type":"uint256"}],"name":"submitWork","outputs":[],"stateMutability":"nonpayable","type":"function"},
    {"inputs":[{"internalType":"uint256","name":"_id","type":"uint256"}],"name":"approve","outputs":[],"stateMutability":"nonpayable","type":"function"},
    {"inputs":[{"internalType":"uint256","name":"","type":"uint256"}],"name":"tasks","outputs":[{"internalType":"address","name":"requester","type":"address"},{"internalType":"address","name":"worker","type":"address"},{"internalType":"uint96","name":"amount","type":"uint96"},{"internalType":"uint40","name":"deadline","type":"uint40"},{"internalType":"uint8","name":"status","type":"uint8"}],"stateMutability":"view","type":"function"},
    {"inputs":[],"name":"taskCount","outputs":[{"internalType":"uint256","name":"","type":"uint256"}],"stateMutability":"view","type":"function"},
    {"anonymous":False,"inputs":[{"indexed":True,"internalType":"uint256","name":"id","type":"uint256"},{"indexed":True,"internalType":"address","name":"requester","type":"address"},{"indexed":False,"internalType":"uint96","name":"amount","type":"uint96"}],"name":"TaskCreated","type":"event"}
]

# ═══════════════════════════════════════════════════════════════
# 🚀 MAIN
# ═══════════════════════════════════════════════════════════════

def main():
    banner()
    
    if not PRIVATE_KEY:
        print("❌ Error: Set PRIVATE_KEY environment variable")
        return
    
    w3 = Web3(Web3.HTTPProvider(RPC_URL))
    usdc = w3.eth.contract(address=USDC_ADDRESS, abi=USDC_ABI)
    judgepay = w3.eth.contract(address=JUDGEPAY_ADDRESS, abi=JUDGEPAY_ABI)
    
    section("📡 CONNECTING TO BASE SEPOLIA")
    info(f"RPC: {RPC_URL}")
    info(f"Block: {w3.eth.block_number}")
    success("Connected!")
    
    section("📋 CONTRACT INFO")
    info(f"JudgePay: {JUDGEPAY_ADDRESS}")
    info(f"USDC:     {USDC_ADDRESS}")
    
    task_count = judgepay.functions.taskCount().call()
    info(f"Total Tasks Created: {task_count}")
    
    section("💰 WALLET BALANCE")
    balance = usdc.functions.balanceOf(MY_ADDRESS).call()
    money(f"USDC Balance: {balance / 10**6} USDC")
    
    eth_balance = w3.eth.get_balance(MY_ADDRESS)
    money(f"ETH Balance:  {w3.from_wei(eth_balance, 'ether')} ETH")
    
    section("🔍 EXISTING TASKS")
    status_map = {0: "🟢 Open", 1: "🟡 Submitted", 2: "✅ Completed", 3: "🔴 Refunded"}
    
    for i in range(min(task_count, 5)):  # Show up to 5 tasks
        task = judgepay.functions.tasks(i).call()
        print(f"\n  Task #{i}")
        print(f"    Requester: {task[0][:10]}...")
        print(f"    Worker:    {task[1][:10]}..." if task[1] != "0x0000000000000000000000000000000000000000" else "    Worker:    (none)")
        print(f"    Amount:    {task[2] / 10**6} USDC")
        print(f"    Status:    {status_map.get(task[4], 'Unknown')}")
    
    section("🎉 DEMO COMPLETE")
    print("""
  This demo shows JudgePay's core functionality:
  
  1. ✅ USDC Escrow - Funds locked in smart contract
  2. ✅ Task Creation - Requester posts bounty
  3. ✅ Work Submission - Worker claims task
  4. ✅ Conditional Release - Payment on approval
  
  🔗 GitHub: https://github.com/Techfrontiers/judgepay
  🐦 MoltX:  @sdsydear
  
  Built with 💀 by Akay for the Agent Economy
    """)

if __name__ == "__main__":
    main()
