cre workflow simulate market-automation-workflow --target staging-settings --broadcast



 cre workflow simulate ./market-users-workflow   --target staging-settings   --non-interactive   --trigger-index 2   --http-payload "$(cat ./market-users-workflow/payload/sponsor.json)" --broadcast  


 cre workflow simulate ./market-users-workflow   --target staging-settings   --non-interactive   --trigger-index 2   --http-payload "$(cat ./market-users-workflow/payload/execute.json)" --broadcast     



 agentes


cre workflow simulate ./agents-workflow   --target staging-settings   --non-interactive   --trigger-index 0   --http-payload "$(cat ./market-users-workflow/payload/agent-plan.json)" --broadcast  



  cre workflow simulate ./agents-workflow   --target staging-settings   --non-interactive   --trigger-index 1   --http-payload "$(cat ./market-users-workflow/payload/agent-sponsor.json)" --broadcast  

  cre workflow simulate ./agents-workflow   --target staging-settings   --non-interactive   --trigger-index 2   --http-payload "$(cat ./market-users-workflow/payload/agent-execute.json)" --broadcast  