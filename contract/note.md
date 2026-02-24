send verified nullifie and adddress to contracts


base Macket Factory Address: 0x89D7F9aA690cDCB2265351FcA0fD260Ed0c7608E

base Prediction Market Bridge Address: 0xBA08Ffb458fBb7F6E05E32Eb681564A0F881200F




arb bridge address: 0xa604Ae032711761B9c0750Cc7Fb45D947063610a

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
