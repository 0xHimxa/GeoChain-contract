will need to make it posible market facotry to buy to it can try to fix price if it getting messy


fix:cre reslove reverting if it incolusive which set state to revview

if gemeni responce is incluew will nned to set proof as "https:"
 
a event handler that resolve marker factory the moment event resolved 


1) succefully setUp cron to check factory balance for refill
 2)  implemented a Gemini helper function for  creating, resloving and checking for dublicate event
  did created a function that will all worlkflow to write to db
3)  compelete a  creating event handler
4) complested resloving market handler
5) completed price sycn
6) completed arbitrage fixing


cre workflow simulate ./cre/market-automation-workflow \
  --non-interactive \
  --trigger-index 1 \
  --http-payload '{"requestId":"manual_sponsor_1","chainId":84532,"action":"addLiquidity","amountUsdc":"1000000","sender":"0xA85926f9598AA43A2D8f24246B5e7886C4A5FeEc","slippageBps":100}' \
  --target staging-settings



{"requestId":"ui_1772173924738_edd75eab","chainId":84532,"action":"swapYesForNo","amountUsdc":"1000000","sender":"0xa85926f9598aa43a2d8f24246b5e7886c4a5feec","slippageBps":150,"session":{"sessionId":"sess_1772173912261_5f664afea4ac25b9","owner":"0xa85926f9598aa43a2d8f24246b5e7886c4a5feec","sessionPublicKey":"0x049feafb4d5d8f87f77e12394c632865a009cc7573c7446e9c483316cb68b53abc9bba3d6a9dbd08413ba137e9460d4820e3737a61562b25b7bf5c65973336d63c","chainId":84532,"allowedActions":["addLiquidity","removeLiquidity","swapNoForYes","swapYesForNo"],"maxAmountUsdc":"10000000","expiresAtUnix":1772177512,"grantSignature":"0xf1067e506ee11c24cdc978cf74d0a71dbfd2383dd56fd1c48a235d457e82ecde29c1577ea7889017653610a7d1f2759cdab9c3093392611878e775a10ebc34961c","requestNonce":"nonce_e3c46eff431f83da74a3e480","requestSignature":"0xe1610ec189b1cebc131ca8c5f9c719eecf1e095479248cc835cf14f5da05d0964956856f81d2be6d422d094d94acc321f32a7bf3e1752534dfc365c5d1e579a01b"}}

 
