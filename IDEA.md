This project is a neovim plugin. It should allow interactive communication with
LLMs by implement a "thread" concept around text objects.

The usability should be:
    - User selects one text range, invoke a command and is prompt to type something
    - After, he could select other texts, and add comments and leave as it is
    - Then, he should be able to send all the texts/questiones to be answered
      by an LLM in each thread itself (this need to be possible for all the
      pending comments or to a single one, 2 commands)

Musts:
    - The thread itself should be visible in the file it was created, but
      SHOULD not be part of it. It should be stored in other place that does
      not interfere with the code and is not tracked in the repo, like
      stdpath('data')/threads.nvim/<hashed-path>.json
    - We should be able to navigate the threads with keyboard shortcuts (a
      `next()` and `prev()` implementation is the better approach and thus
      mapping `]r` and `[r`)
    - We need to have and option also to apply requested changes on the thread
      to the whole file
    - The whole file should be sent to the LLM for more context
    - We should be able to toggle the threads to avoid polluition
    - Along with the bullet above, we could use extmarks to avoid real write in the file
    - We should have a command to delete one or all the threads in the file
    - The thread should be associated with one or a set of lines. If those
      change, we should close the thread to avoid confusion
    - Having in mind that the threads can be closed, we should also have a
      history of threads to track (a command that would open an interactive
      window with old threads)
    - We should have enough interface to be able to integrate htis with other
      plugins, such as pickers for fuzzy find threads
    - We should NOT need a specific plugin for this to work. We should support
      any agent/binary the user already have in his machine (command
      configurable at setup) for example opencode, codex, PI, etc
    - The thread model is multi-turn conversation.
    - The thread have states (pending/sent/answered)
    - We need a visual feedback for when we are waiting a LLM response and when it is
      done answering questions or applying changes
    - The comments/questions should be prompted with floating windows
    - The keymaps should be USER configurable via (neo)vim native commands and
      we should not enforce what the user should use
    - The requests should be sent ASYNC, not blocking other user actions
      including other threads process
    - Any change to the file that should be caused by an LLM need to be made by
      the agent itself. Neovim will not handle diffs/chunk reviews for now.
