import json
from web3 import Web3
import os
import time

# Configuration - V2 Contract
RPC_URL = "https://sepolia.base.org"
JUDGEPAY_ADDRESS = Web3.to_checksum_address("0xA5D4B9dFdFd8EEee1335336B8A5ba766De717e11")
USDC_ADDRESS = Web3.to_checksum_address("0x036CbD53842c5426634e7929541eC2318f3dCF7e")
PRIVATE_KEY = os.environ.get("PRIVATE_KEY")
MY_ADDRESS = Web3.to_checksum_address("0x4a6a4Db15Ce7C892f62c750fDcC0D34d11572a99")

# ABI
USDC_ABI = [
    {"inputs":[{"internalType":"address","name":"spender","type":"address"},{"internalType":"uint256","name":"value","type":"uint256"}],"name":"approve","outputs":[{"internalType":"bool","name":"","type":"bool"}],"stateMutability":"nonpayable","type":"function"},
    {"inputs":[{"internalType":"address","name":"account","type":"address"}],"name":"balanceOf","outputs":[{"internalType":"uint256","name":"","type":"uint256"}],"stateMutability":"view","type":"function"}
]

JUDGEPAY_ABI = [
    {"inputs":[{"internalType":"uint96","name":"_amount","type":"uint96"},{"internalType":"uint40","name":"_deadlineHours","type":"uint40"}],"name":"createTask","outputs":[{"internalType":"uint256","name":"","type":"uint256"}],"stateMutability":"nonpayable","type":"function"},
    {"inputs":[{"internalType":"uint256","name":"_id","type":"uint256"}],"name":"submitWork","outputs":[],"stateMutability":"nonpayable","type":"function"},
    {"inputs":[{"internalType":"uint256","name":"_id","type":"uint256"}],"name":"approve","outputs":[],"stateMutability":"nonpayable","type":"function"},
    {"inputs":[{"internalType":"uint256","name":"","type":"uint256"}],"name":"tasks","outputs":[{"internalType":"address","name":"requester","type":"address"},{"internalType":"address","name":"worker","type":"address"},{"internalType":"uint96","name":"amount","type":"uint96"},{"internalType":"uint40","name":"deadline","type":"uint40"},{"internalType":"uint8","name":"status","type":"uint8"}],"stateMutability":"view","type":"function"},
    {"inputs":[],"name":"taskCount","outputs":[{"internalType":"uint256","name":"","type":"uint256"}],"stateMutability":"view","type":"function"},
    {"anonymous":False,"inputs":[{"indexed":True,"internalType":"uint256","name":"id","type":"uint256"},{"indexed":True,"internalType":"address","name":"requester","type":"address"},{"indexed":False,"internalType":"uint96","name":"amount","type":"uint96"}],"name":"TaskCreated","type":"event"}
]

def main():
    if not PRIVATE_KEY:
        print("❌ Error: PRIVATE_KEY env var missing")
        return

    w3 = Web3(Web3.HTTPProvider(RPC_URL))
    print(f"🔗 Connected to Base Sepolia (Block: {w3.eth.block_number})")
    
    usdc = w3.eth.contract(address=USDC_ADDRESS, abi=USDC_ABI)
    judgepay = w3.eth.contract(address=JUDGEPAY_ADDRESS, abi=JUDGEPAY_ABI)
    
    balance = usdc.functions.balanceOf(MY_ADDRESS).call()
    print(f"💰 USDC Balance: {balance / 10**6} USDC")
    
    # 1. Approve
    print("\n[1] Approving JudgePay V2...")
    nonce = w3.eth.get_transaction_count(MY_ADDRESS)
    tx = usdc.functions.approve(JUDGEPAY_ADDRESS, 100 * 10**6).build_transaction({
        'chainId': 84532, 'gas': 100000, 'gasPrice': w3.eth.gas_price, 'nonce': nonce
    })
    signed_tx = w3.eth.account.sign_transaction(tx, PRIVATE_KEY)
    tx_hash = w3.eth.send_raw_transaction(signed_tx.raw_transaction)
    print(f"✅ Approved! TX: {w3.to_hex(tx_hash)}")
    w3.eth.wait_for_transaction_receipt(tx_hash)
    
    # 2. Create Task
    print("\n[2] Creating Task (2 USDC)...")
    nonce = w3.eth.get_transaction_count(MY_ADDRESS)
    tx = judgepay.functions.createTask(2 * 10**6, 24).build_transaction({
        'chainId': 84532, 'gas': 200000, 'gasPrice': w3.eth.gas_price, 'nonce': nonce
    })
    signed_tx = w3.eth.account.sign_transaction(tx, PRIVATE_KEY)
    tx_hash = w3.eth.send_raw_transaction(signed_tx.raw_transaction)
    print(f"✅ Task Created! TX: {w3.to_hex(tx_hash)}")
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash)
    print(f"   Block: {receipt['blockNumber']}")
    
    task_count = judgepay.functions.taskCount().call()
    task_id = task_count - 1
    print(f"🎉 Task ID: {task_id}")
    
    # 3. Create Worker & Fund
    print("\n[3] Creating demo worker...")
    worker = w3.eth.account.create()
    nonce = w3.eth.get_transaction_count(MY_ADDRESS)
    tx = {'nonce': nonce, 'to': worker.address, 'value': w3.to_wei(0.001, 'ether'),
          'gas': 21000, 'gasPrice': w3.eth.gas_price, 'chainId': 84532}
    signed_tx = w3.eth.account.sign_transaction(tx, PRIVATE_KEY)
    w3.eth.send_raw_transaction(signed_tx.raw_transaction)
    time.sleep(3)
    print(f"✅ Worker: {worker.address}")
    
    # 4. Submit Work
    print("\n[4] Worker submitting...")
    nonce = w3.eth.get_transaction_count(worker.address)
    tx = judgepay.functions.submitWork(task_id).build_transaction({
        'chainId': 84532, 'gas': 100000, 'gasPrice': w3.eth.gas_price, 'nonce': nonce
    })
    signed_tx = w3.eth.account.sign_transaction(tx, worker.key.hex())
    tx_hash = w3.eth.send_raw_transaction(signed_tx.raw_transaction)
    print(f"✅ Work Submitted! TX: {w3.to_hex(tx_hash)}")
    w3.eth.wait_for_transaction_receipt(tx_hash)
    
    # 5. Approve & Release
    print("\n[5] Requester approving...")
    nonce = w3.eth.get_transaction_count(MY_ADDRESS)
    tx = judgepay.functions.approve(task_id).build_transaction({
        'chainId': 84532, 'gas': 100000, 'gasPrice': w3.eth.gas_price, 'nonce': nonce
    })
    signed_tx = w3.eth.account.sign_transaction(tx, PRIVATE_KEY)
    tx_hash = w3.eth.send_raw_transaction(signed_tx.raw_transaction)
    print(f"✅ Payment Released! TX: {w3.to_hex(tx_hash)}")
    w3.eth.wait_for_transaction_receipt(tx_hash)
    
    # Final
    task = judgepay.functions.tasks(task_id).call()
    status_map = {0: "Open", 1: "Submitted", 2: "Completed", 3: "Refunded"}
    print(f"\n🏆 Task #{task_id} Final Status: {status_map.get(task[4], 'Unknown')}")
    print(f"💸 Worker received: 2 USDC")
    
    balance = usdc.functions.balanceOf(MY_ADDRESS).call()
    print(f"💰 Remaining Balance: {balance / 10**6} USDC")

if __name__ == "__main__":
    main()
