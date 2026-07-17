# USD8 Decision Trade-offs

This document records major architectural and economic trade-offs that USD8 knowingly accepts for the current version. It is not a list of minor findings or ordinary admin privileges.

## Complete

### 1. Unfinalized claim allocations are not redistributed

Settlement allocates each claimant a maximum payout before users finalize. A claimant may choose not to finalize or may fail to do so before the deadline.

- Their allocation remains unpaid and stays with the cover pools.
- Other claimants do not receive a second calculation or redistribution.
- Recomputing after every missed finalization would add another settlement round and make payouts non-final.

**Accepted trade-off:** a non-finalizing claimant can reduce capital utilization for that incident, but cannot take the unused funds.

### 2. Treasury strategies inherit external ERC-4626 risks

Treasury USDC may be deployed into approved external ERC-4626 vaults. USD8 does not attempt to reproduce or fully isolate their liquidity, accounting, governance, oracle, or smart-contract risks.

- A donation or inflation manipulation may make a deployment revert even though value-short deposits are rejected.
- A strategy can become illiquid and temporarily block redemptions that require its funds.
- Governance must use established, deeply liquid vaults and keep less-liquid strategies later in the withdrawal queue.

**Accepted trade-off:** using vetted external yield infrastructure avoids building another lending system, but USD8 inherits part of that infrastructure's risk and availability.

### 3. Strategy accounting fails closed

Treasury reserve accounting directly reads every approved strategy's `totalAssets()`. One reverting strategy can therefore block reserve reads, minting, redemption, and harvesting.

- Silently ignoring a failed strategy would overstate or understate USD8 backing without a trustworthy value.
- Timelock can force-remove the broken strategy to recover protocol liveness.
- Force-removing a funded strategy excludes its assets from reserve accounting and may orphan recoverable funds, making USD8 appear undercollateralized.

**Accepted trade-off:** uncertain reserves stop the system rather than being guessed; emergency recovery may recognize a strategy as lost.
