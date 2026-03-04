this for base, if want to use it for arbitrum change the index to 6 and past arb tx in the tx place:


cre workflow simulate ./market-workflow   --target staging-settings   --non-interactive   --trigger-index 6   --evm-tx-hash 0x286ae57fc9ad77f5dea9ca4a8a8441cba7a558aa4388fa3f04bfaf4402604bf0   --evm-event-index 0   --broadcast


 cre workflow simulate ./market-workflow   --target staging-settings   --non-interactive   --trigger-index 4   --evm-tx-hash  0xdd685d92c28a451b9341a80002e7a6b6244eb724e3af951dc789d320a9479496   --evm-event-index 0   --broadcast