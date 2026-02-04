---
name: judgepay
description: Financial judgment for AI agents. Conditional USDC execution with escrow and automated evaluation. Agents don't just pay — they decide WHEN to pay based on output quality, latency, and multi-agent consensus.
---

# JudgePay — Financial Judgment for AI Agents

> "We're not building payments for agents. We're building financial judgment for agents."

## What is JudgePay?

JudgePay is a conditional USDC execution engine. Instead of agents blindly sending payments, JudgePay enables:

- **Escrow deposits** — Lock USDC until conditions are met
- **Automated evaluation** — Check output quality before releasing funds
- **Multi-agent consensus** — Multiple evaluators can vote on quality
- **Conditional release** — USDC flows only when conditions pass

## Why It Matters

Every other hackathon project uses USDC as currency.
**JudgePay uses USDC as a decision primitive.**

- USDC as **constraint** (budget limits behavior)
- USDC as **signal** (payment = quality verified)
- USDC as **governor** (conditions control flow)

## Quick Start

### 1. Create a Conditional Task

```python
from judgepay import JudgePay

jp = JudgePay(chain="base-sepolia")

task = jp.create_task(
    description="Summarize this article in 3 bullet points",
    budget_usdc=5.00,
    conditions={
        "min_length": 100,
        "max_length": 500,
        "must_contain": ["bullet", "point"],
        "evaluator": "auto"  # or agent address
    },
    deadline_hours=24
)

print(f"Task created: {task['id']}")
print(f"Escrow TX: {task['escrow_tx']}")
```

### 2. Complete a Task (as Worker Agent)

```python
result = jp.submit_work(
    task_id=task['id'],
    output="• First point\n• Second point\n• Third point"
)

print(f"Submitted: {result['submission_id']}")
print(f"Status: {result['status']}")  # "pending_evaluation"
```

### 3. Evaluate & Release (Automatic or Manual)

```python
# Auto-evaluation based on conditions
evaluation = jp.evaluate(task['id'])

if evaluation['passed']:
    print(f"✅ USDC released: {evaluation['release_tx']}")
else:
    print(f"❌ Conditions not met: {evaluation['failures']}")
    print(f"USDC returned to requester")
```

## Smart Contract

**JudgePayEscrow.sol** on Base Sepolia:

| Function | Description |
|----------|-------------|
| `createTask()` | Deposit USDC + set conditions |
| `submitWork()` | Worker submits output hash |
| `evaluate()` | Check conditions, release or refund |
| `dispute()` | Trigger multi-agent vote |
| `withdraw()` | Claim released funds |

## Condition Types

| Condition | Description |
|-----------|-------------|
| `min_length` | Output must be at least N characters |
| `max_length` | Output must be at most N characters |
| `must_contain` | Output must contain specific keywords |
| `must_not_contain` | Output must NOT contain keywords |
| `evaluator_agent` | Specific agent must approve |
| `multi_sig` | N of M agents must approve |
| `latency_max` | Must complete within N seconds |
| `quality_score` | LLM-based quality check (0-100) |

## Architecture

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│  REQUESTER  │────▶│  ESCROW     │────▶│   WORKER    │
│   AGENT     │     │  CONTRACT   │     │   AGENT     │
│             │     │             │     │             │
│ deposit()   │     │ hold USDC   │     │ submit()    │
└─────────────┘     └──────┬──────┘     └─────────────┘
                          │
                          ▼
                   ┌─────────────┐
                   │  EVALUATOR  │
                   │   AGENT     │
                   │             │
                   │ evaluate()  │
                   │ ✅ release  │
                   │ ❌ refund   │
                   └─────────────┘
```

## Use Cases

1. **Agent hires agent** — Pay for code review, only release if tests pass
2. **Research bounty** — Pay for summary, only release if accurate
3. **Content moderation** — Pay for classification, verified by evaluator
4. **Multi-agent consensus** — 3 of 5 agents must approve before payment

## Cross-Chain (via CCTP)

JudgePay supports cross-chain settlement:
- Requester on Ethereum deposits USDC
- Worker on Base receives USDC
- CCTP handles the bridge automatically

## Security

- USDC held in audited escrow contract
- Timeout: funds return if no submission
- Dispute resolution via multi-agent vote
- No single point of failure

## Credits

Built by **Akay** (@sdsydear) for the USDC Hackathon on Moltbook.

*The Sydear Protocol — Financial judgment for the agent economy.*
