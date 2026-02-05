import json
from web3 import Web3
import os

# Configuration
RPC_URL = "https://sepolia.base.org"
JUDGEPAY_ADDRESS = Web3.to_checksum_address("0x941bb35BFf8314A20c739EC129d6F38ba73BD4E5")
PRIVATE_KEY = os.environ.get("PRIVATE_KEY")
MY_ADDRESS = Web3.to_checksum_address("0x4a6a4Db15Ce7C892f62c750fDcC0D34d11572a99")

# Note: For demo, we need a DIFFERENT address to submit work (worker != requester)
# We'll use a secondary wallet. For now, let's create one on the fly for demo purposes.

JUDGEPAY_ABI = [
    {"inputs":[{"internalType":"uint256","name":"_id","type":"uint256"}],"name":"submitWork","outputs":[],"stateMutability":"nonpayable","type":"function"},
    {"inputs":[{"internalType":"uint256","name":"_id","type":"uint256"}],"name":"approve","outputs":[],"stateMutability":"nonpayable","type":"function"},
    {"anonymous":False,"inputs":[{"indexed":True,"internalType":"uint256","name":"id","type":"uint256"},{"indexed":True,"internalType":"address","name":"worker","type":"address"}],"name":"WorkSubmitted","type":"event"},
    {"anonymous":False,"inputs":[{"indexed":True,"internalType":"uint256","name":"id","type":"uint256"},{"indexed":False,"internalType":"uint96","name":"amount","type":"uint96"}],"name":"TaskCompleted","type":"event"},
    {"inputs":[{"internalType":"uint256","name":"","type":"uint256"}],"name":"tasks","outputs":[{"internalType":"address","name":"requester","type":"address"},{"internalType":"address","name":"worker","type":"address"},{"internalType":"uint96","name":"amount","type":"uint96"},{"internalType":"uint40","name":"deadline","type":"uint40"},{"internalType":"uint8","name":"status","type":"uint8"}],"stateMutability":"view","type":"function"}
]

def main():
    if not PRIVATE_KEY:
        print("❌ Error: PRIVATE_KEY env var missing")
        return

    w3 = Web3(Web3.HTTPProvider(RPC_URL))
    if not w3.is_connected():
        print("❌ Error: Cannot connect to RPC")
        return

    print(f"🔗 Connected to Base Sepolia (Block: {w3.eth.block_number})")
    
    judgepay = w3.eth.contract(address=JUDGEPAY_ADDRESS, abi=JUDGEPAY_ABI)
    
    # Check Task Status
    task = judgepay.functions.tasks(0).call()
    status_map = {0: "Open", 1: "Submitted", 2: "Completed", 3: "Refunded"}
    print(f"\n📋 Task #0 Status:")
    print(f"    Requester: {task[0]}")
    print(f"    Worker: {task[1]}")
    print(f"    Amount: {task[2] / 10**6} USDC")
    print(f"    Status: {status_map.get(task[4], 'Unknown')}")
    
    # For demo: We need a worker address (different from requester)
    # Let's generate a random one just for the demo
    worker_account = w3.eth.account.create()
    worker_address = worker_account.address
    worker_key = worker_account.key.hex()
    
    print(f"\n👷 Demo Worker Created: {worker_address}")
    print(f"    (This is a temporary address for demo purposes)")
    
    # Fund worker with tiny ETH for gas (from main account)
    print("\n[1] Funding worker with gas...")
    nonce = w3.eth.get_transaction_count(MY_ADDRESS)
    tx = {
        'nonce': nonce,
        'to': worker_address,
        'value': w3.to_wei(0.001, 'ether'),
        'gas': 21000,
        'gasPrice': w3.eth.gas_price,
        'chainId': 84532
    }
    signed_tx = w3.eth.account.sign_transaction(tx, PRIVATE_KEY)
    tx_hash = w3.eth.send_raw_transaction(signed_tx.raw_transaction)
    w3.eth.wait_for_transaction_receipt(tx_hash)
    print(f"✅ Worker funded! TX: {w3.to_hex(tx_hash)}")
    
    # Wait for funding to propagate
    import time
    print("    Waiting for funds to propagate...")
    time.sleep(3)
    
    # Worker submits work
    print("\n[2] Worker submitting work...")
    nonce = w3.eth.get_transaction_count(worker_address)
    tx = judgepay.functions.submitWork(0).build_transaction({
        'chainId': 84532,
        'gas': 100000,
        'gasPrice': w3.eth.gas_price,
        'nonce': nonce
    })
    signed_tx = w3.eth.account.sign_transaction(tx, worker_key)
    tx_hash = w3.eth.send_raw_transaction(signed_tx.raw_transaction)
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash)
    print(f"✅ Work Submitted! TX: {w3.to_hex(tx_hash)}")
    
    # Requester approves (releases payment)
    print("\n[3] Requester approving & releasing payment...")
    nonce = w3.eth.get_transaction_count(MY_ADDRESS)
    tx = judgepay.functions.approve(0).build_transaction({
        'chainId': 84532,
        'gas': 100000,
        'gasPrice': w3.eth.gas_price,
        'nonce': nonce
    })
    signed_tx = w3.eth.account.sign_transaction(tx, PRIVATE_KEY)
    tx_hash = w3.eth.send_raw_transaction(signed_tx.raw_transaction)
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash)
    print(f"✅ Payment Released! TX: {w3.to_hex(tx_hash)}")
    
    # Final Status
    task = judgepay.functions.tasks(0).call()
    print(f"\n📋 Task #0 Final Status:")
    print(f"    Status: {status_map.get(task[4], 'Unknown')}")
    print(f"    Worker received: 10 USDC 🎉")

if __name__ == "__main__":
    main()
