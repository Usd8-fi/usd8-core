# Protocol-wide formal-verification scope and provenance

Snapshot boundary: the production sources and artifacts authenticated by the hash tables below, compiled with `FOUNDRY_PROFILE=kontrol` using Solidity 0.8.28, Cancun, optimizer enabled, and resolved optimizer runs **1**.

## Deployable census and candidate accounting

| Production contract | Role | Formal candidates | `*KontrolTest` classes | Current evidence status |
|---|---|---:|---:|---|
| `USD8PriceOracle` | Composite reserve-price oracle | 33 | 1 | Forge-green candidate definitions; 0 solver-proved |
| `USD8SavingsAdapter` | Savings-vault allocation adapter | 50 | 2 | Forge-green candidate definitions; 0 solver-proved |
| `USD8SavingsBootstrap` | One-shot savings deployment/bootstrap | 116 | 1 | Forge-green candidate definitions; 0 solver-proved |
| `SingleAssetCoverPool` | Underwriting ERC-4626 pool and batched exits | 110 | 7 | Forge-green candidate definitions; 0 solver-proved |
| `ERC4626Strategy` | Treasury external-yield strategy | 124 | 6 | Forge-green candidate definitions; 0 solver-proved |
| `DefiInsurance` | Incident, claim, settlement, and payout lifecycle | 101 | 6 | Forge-green candidate definitions; 0 solver-proved |
| `Treasury` | Reserve accounting and strategy coordinator | 165 | 12 | Forge-green candidate definitions; 0 solver-proved |
| `Registry` | Authority, topology, policy, and upgrade hub | 49 | 5 | Forge-green candidate definitions; 0 solver-proved |
| `USD8` | Stablecoin | 93 | 6 | Forge-green candidate definitions; 0 solver-proved |
| **Total** |  | **841** | **46** | **0 solver-proved** |

The complete conventional executable inventory is 915 `test_*` definitions, of which 74 are Foundry-only/non-Kontrol. Seven camel-named ERC4626Strategy integration checks are outside that approved conventional inventory.

Non-deployable production sources remain separately classified:

- `SharedBase` — abstract; inherited behavior is assigned through concrete deployable families.
- `StrategyBase` — abstract; behavior is assigned through `ERC4626Strategy`.
- `IStrategy` and `IProfitDistributionReceiver` — interfaces and model boundaries, not deployables.

## Current compiled ABI matrix

Counts are from the authenticated production artifacts. Function counts include inherited public/external ABI entries and are split by state mutability.

| Deployable | Functions | View | Pure | Nonpayable | Payable | Events | Errors |
|---|---:|---:|---:|---:|---:|---:|---:|
| `USD8PriceOracle` | 8 | 6 | 2 | 0 | 0 | 0 | 6 |
| `USD8SavingsAdapter` | 10 | 9 | 0 | 1 | 0 | 1 | 4 |
| `USD8SavingsBootstrap` | 3 | 2 | 0 | 1 | 0 | 0 | 6 |
| `SingleAssetCoverPool` | 58 | 37 | 4 | 17 | 0 | 17 | 42 |
| `ERC4626Strategy` | 12 | 7 | 0 | 5 | 0 | 6 | 21 |
| `DefiInsurance` | 38 | 22 | 0 | 15 | 1 | 22 | 47 |
| `Treasury` | 29 | 15 | 0 | 13 | 1 | 17 | 30 |
| `Registry` | 61 | 35 | 0 | 25 | 1 | 25 | 33 |
| `USD8` | 23 | 13 | 0 | 9 | 1 | 8 | 27 |

This table is the protocol-wide ABI/event/error count matrix. Detailed path classification remains in the contract closure documents where present. Event and error **name-union closure is not solver evidence**: every reachable path still needs an executable witness, and structural/preempted rows need source-backed exclusions.

## Recomputed source and ABI hashes

SHA-256 values below authenticate the frozen source and artifact bytes. ABI hashes use compact JSON with recursively sorted object keys while preserving the artifact ABI array order, matching the established workspace recipe.

| Deployable | Production source SHA-256 | Canonical ABI SHA-256 |
|---|---|---|
| `USD8PriceOracle` | `9e40f29b58ced4a9887a33e6d6fcc865881e8d9f9451661d928d61e6ae6c2dda` | `5814bdedf16b19b3060ad98b158a7d2e4b23b868325fef580d90472fb475d70d` |
| `USD8SavingsAdapter` | `4459666927f6ebc945bbffa0bc81557d35d3be664e75936603c759a315204f63` | `d416f281dcd92c69b0d9bc2d2c77e3b607ceacb909c544e86487d5170fd04128` |
| `USD8SavingsBootstrap` | `40eff36da3a8e8559c7176720af5a63e16eb59b67f34a249a9b8109b412e2383` | `21d0e0d1b1b0dc731c6f0571ca052cb1abf77410acf971e9fbc89c64bb22527b` |
| `SingleAssetCoverPool` | `9524efa4e4f59401722affef256b1ea051e586cde11f7ca7a53a743db684518b` | `02efb24b6d06c4c636f1af016b29fc5da11f9d90ed5df9918b35be2a999372ec` |
| `ERC4626Strategy` | `7e51d6fe0acbdf3704f6676b54b6ad30b976d89fea673e31435c71ba23cf490c` | `070db212ad57d4c52f35f9541fc7851c8cff61bf5cb414d999845e3f0dd5f729` |
| `DefiInsurance` | `42be9763332f8d6a960d5b9d76308457e1ab45603e4279657535660a0368907e` | `f603871d64d79b26bc034c7aababfe07e36485757fefbb258c17909d813fe4c5` |
| `Treasury` | `f9d3220777142352dbc11cf32ce9ca2f24c9b6cf4389df093f7cbff37d1a96a2` | `e9eeb1b8919f7b75a355e53fcfc42c0ef7b51adfc1191f0f7aa962f5024fac84` |
| `Registry` | `bcdfdc1a0c07d1a2c5b18aa46946cfda097420c334ef3c16d522016571a52ae5` | `27cd38dae90cf604c8be65a9693b80ebe6882901a6951212601548c79962905f` |
| `USD8` | `cdfa06a4b87b8b7f5b8374911c7d7315aa5f9cfb806f9250288e53067dbe77a6` | `a2bae65405b50cb4351de1cda47336b0373f64e8325970e39b0d7bb4762b5350` |

## Recomputed bytecode hashes

Hashes are over decoded artifact bytecode bytes, not the ASCII hex representation.

| Deployable | Creation bytes | Creation SHA-256 | Runtime bytes | Runtime SHA-256 |
|---|---:|---|---:|---|
| `USD8PriceOracle` | 2,857 | `1ee598ec31e2f59cabcbab4996cbab68e86e91b03386ff27953d36061ee5b74a` | 2,281 | `2fcbcb144569528caf116697053f19d72d0eeb82c4ca4df402a24871825055bb` |
| `USD8SavingsAdapter` | 3,129 | `2c9faebd537af0ff66f03186c59461ee283bcdcc56d19e4cd764eba9e6704cba` | 2,459 | `869ab2ef3a1a046743f85f5ca75f2cea2c71a416af0c9a65cce97dee4c1cff51` |
| `USD8SavingsBootstrap` | 6,781 | `4996e44172fabf810dbc3aad1de7fc91eb4e99ac9efc60bdde288452b7ec0603` | 6,732 | `55968041a6e7f7b0e3146522a14a1224491286d9aead0c18d54812c571e92c96` |
| `SingleAssetCoverPool` | 16,069 | `84c9ad5e6f9ea72863664aa9609dce8e342ceba033d530ee294aecbe4830ed09` | 15,855 | `4e90539acfcd030394a8b9a6538e39541a0f0d45c9c0ed2f1a485f85d5033bf4` |
| `ERC4626Strategy` | 6,810 | `9b6c976eb260b2945343f5651a3b8f6adf61a40255d0f9c718270fdf5c3f23cd` | 5,456 | `c0046953b64f87d9f7dec1c9fd01635eb14b1dfb227348c0104d742bcb0cf7f8` |
| `DefiInsurance` | 24,017 | `33e86476e9104faed337fa8c9dc2a0468bacf2f5febbc771ea47378ba717592e` | 23,768 | `9effcdbb276ac72529578810f7f5caf07662d1bc35408360962e77ce4de4acd5` |
| `Treasury` | 14,223 | `02c0e4f6a0e9d3e2b7c1399a8a9d3742a53506507de89d77601c578b24e2ea8b` | 13,974 | `cfe752f2f58dcf404c3f03fb74738d9c81b5e6132c270b77621df92c742a08e3` |
| `Registry` | 14,826 | `3b3ac27e374d0349abc7ab8c774ef237195a9171313c0a3b0c68f32d7fa21491` | 14,577 | `512c00acabf3cf4aba6086c0c700d489d5822fbd703c479de7620a61e86b4ae1` |
| `USD8` | 8,009 | `64a7f33ddf9186cf5b259847b4c8e11afb53b83bb634f132324033d8a25c8380` | 7,760 | `e8d26241d5437142c4ff47071e82e53264d9dbba31f04abf4d3993b259bbebf2` |

These hashes bind the frozen compiler artifacts, including Solidity metadata. Any source, imported dependency, compiler setting, or metadata-affecting change invalidates them.

## Approved assumptions and closure boundary

1. Candidate definitions are Forge-green; **0/841 are solver-proved** until a clean campaign produces snapshot-authenticated accepted reports.
2. Approved router entries curate `(target, spender)` only. They do not constrain arbitrary calldata or downstream calls. Router, vault, token, Treasury callback, and share-value claims are conditional on the named models in the family documents.
3. Later-log ordering and call-indexed behavior remain Foundry-only when unsupported by Kontrol v1.0.255.
4. Scalar widths, representative addresses, collection sizes, callback depth, and lifecycle length are bounded where documented. No bounded theorem may be described as universal over arbitrary bytecode or unbounded arrays.
5. Named reviewed upgrades are modeled; arbitrary future implementation safety is excluded.
6. Solver claims apply only to the exact authenticated snapshot; working-tree state or generated local output is not verification evidence.

Protocol-wide solver closure additionally requires a clean immutable input snapshot, the Cancun transient-storage environment gate, exact-signature family reports, zero failed/pending/stuck/timed-out/admitted branches, and a regenerated validator/manifest that authenticates all 841 candidates and all nine production artifacts.
