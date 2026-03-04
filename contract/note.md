send verified nullifie and adddress to contracts


base Macket Factory Address: 0x89D7F9aA690cDCB2265351FcA0fD260Ed0c7608E

base Prediction Market Bridge Address: 0x770B733050f07D93fa827ac82230c0eD9baB4A6c




arb bridge address: 0xc90E272314115fe79B42741E439a8fD8A58a8aEF

arb market factory address: 0xA8735c76fA6E04f705204100FbE56582f0e420eD





add access control to market deployer


base destination chain

arb source chain

dont forget to call initailaize when upgrading, or  deploy a new proxy again: redploy the proxy again will be much better



will  use cre to check if hub price has changed compare to spoke if so sendbroadcast to them

cre for check spoke balance after certain time so that it awlays have enoguh money to send to user





to update the price i will need to loop through the array of active market and check for price different then update


my bad instead of upgrading i ended up redeploying

sepolia deployed: Market Factory proxy address: 0x7c7fe235fC63509969E329E5D660E073EeFa5d39

arbi 1 sepolia deployed: Market Factory proxy address:0x015a4e609ED01012ff4B9401a274BE84C89052E6


f i dinit not specify the initial liquidity for new event will add minimum in the next upgrade




cast send 0x9e96ad0e4044356918477A36b58bFcb98eAD4566 "approve(address,uint256)" 0xdB5e75aC76136A3e9FFCbFf1DED42f3943aE1701 1000000000 --account "$ACCOUNT" --rpc-url https://arb-sepolia.g.alchemy.com/v2/KJ1Tuwa06gu31_-ICeiaV && \
cast send 0xdB5e75aC76136A3e9FFCbFf1DED42f3943aE1701 "depositCollateral(uint256)" 1000000000 --account wallet  --rpc-url https://arb-sepolia.g.alchemy.com/v2/KJ1Tuwa06gu31_-ICeiaV