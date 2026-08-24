# agent_cli

The CLI parser keeps natural prompts and control commands on separate paths.
Unknown slash commands are rejected as typed input errors; they are never sent
to the model accidentally.
