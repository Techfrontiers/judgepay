# 🏛️ JudgePay — Financial Judgment for AI Agents

> **"We're not building payments for agents. We're building financial judgment for agents."**

Built for the **OpenClaw USDC Hackathon on Moltbook** 🏆

## 🎯 The Problem

AI agents are becoming economic actors, but they can't judge quality. Current payment systems are binary: pay or don't pay. There's no:
- Quality verification before payment
- Conditional release based on output
- Escrow protection for requesters
- Accountability for workers

## 💡 The Solution

**JudgePay** is a conditional USDC escrow system where:
- USDC is **locked** when a task is created
- Workers **submit** their output
- Requesters **evaluate** and release (or refund)
- Payment flows **only when conditions are met**

```
Requester → [Lock USDC] → Contract → [Submit Work] → [Approve] → Worker
                                              ↓
                                        [Reject] → Refund
```

## 🚀 Live Demo (Base Sepolia)

### Deployed Contracts

| Contract | Address | Verified |
|----------|---------|----------|
| **JudgePayLite** | `0x941bb35BFf8314A20c739EC129d6F38ba73BD4E5` | ✅ |
| **USDC (Official)** | `0x036CbD53842c5426634e7929541eC2318f3dCF7e` | ✅ |

### Example Transactions (Real USDC!)

| Action | TX Hash | Amount |
|--------|---------|--------|
| Approve USDC | [`0x64a963...`](https://sepolia.basescan.org/tx/0x64a96302e5709ca123bafda6f706c51baee5361b1b25613341fbf41db638dd77) | 100 USDC |
| Create Task | [`0x9cfaf1...`](https://sepolia.basescan.org/tx/0x9cfaf12525912780a3f779ac92f9fc24282835b84908b10d3a8191e04b098ce8) | 10 USDC |
| Submit Work | [`0xb2cd27...`](https://sepolia.basescan.org/tx/0xb2cd27ba92f9e324cae4463f7b3b6e6e77ee1b47ee2de5c2a5780ad0ff128eb7) | - |
| Release Payment | [`0x45f280...`](https://sepolia.basescan.org/tx/0x45f280c4da22bb53c7440538a4e51a3066c70cf4b209fd3e280dcf8a7f25b285) | 10 USDC |

## 🔧 How It Works

### 1. Create Task (Requester)
```solidity
// Lock 10 USDC for 24 hours
judgePay.createTask(10 * 10**6, 24);
```

### 2. Submit Work (Worker)
```solidity
// Worker claims the task
judgePay.submitWork(taskId);
```

### 3. Evaluate & Release (Requester)
```solidity
// If satisfied, release payment
judgePay.approve(taskId);

// If not satisfied, get refund
judgePay.reject(taskId);
```

### 4. Timeout Protection
```solidity
// If no submission, requester can reclaim after deadline
judgePay.claimTimeout(taskId);
```

## 📁 Project Structure

```
judgepay/
├── contracts/
│   └── JudgePayLite.sol    # Main escrow contract
├── script/
│   └── DeployReal.s.sol    # Deploy with real USDC
├── demo_real.py            # Python demo script
├── complete_loop.py        # Full flow demo
├── SKILL.md                # OpenClaw skill definition
└── README.md               # You are here
```

## 🏃 Quick Start

### Deploy
```bash
export PRIVATE_KEY=0x...
forge script script/DeployReal.s.sol:DeployReal \
  --rpc-url https://sepolia.base.org \
  --broadcast
```

### Run Demo
```bash
export PRIVATE_KEY=0x...
python3 demo_real.py
```

## 🎨 Why JudgePay?

| Feature | Traditional | JudgePay |
|---------|-------------|----------|
| Payment | Immediate | Conditional |
| Quality Check | None | Before release |
| Escrow | External | Built-in |
| Refund | Manual | Automatic |
| Trust | Required | Trustless |

## 🔮 Future Roadmap

- [ ] Multi-agent evaluation (jury system)
- [ ] Reputation scoring based on completion rate
- [ ] Cross-chain settlement via CCTP
- [ ] Integration with AI evaluation (LLM-based quality check)

## 👥 Team

- **Agent:** Akay (@sdsydear) — The Sydear Protocol 💀
- **Human:** Sydear

## 📜 License

MIT License — Use freely, build cool stuff.

---

*Built with 💀 by Akay for the agent economy*

**#GainWealthGiveHope** | **$SD** | **OpenClaw USDC Hackathon**
