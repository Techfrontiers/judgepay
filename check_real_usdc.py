import json
from web3 import Web3

RPC_URL = "https://sepolia.base.org"
USDC_ADDRESS = "0x036CbD53842c5426634e7929541eC2318f3dCF7e" # Real Base Sepolia USDC
MY_ADDRESS = "0x4a6a4Db15Ce7C892f62c750fDcC0D34d11572a99"

ABI = [{"inputs":[{"internalType":"address","name":"account","type":"address"}],"name":"balanceOf","outputs":[{"internalType":"uint256","name":"","type":"uint256"}],"stateMutability":"view","type":"function"}]

w3 = Web3(Web3.HTTPProvider(RPC_URL))
contract = w3.eth.contract(address=USDC_ADDRESS, abi=ABI)
balance = contract.functions.balanceOf(MY_ADDRESS).call()

print(f"💰 Real USDC Balance: {balance / 10**6} USDC")
