# Working in an acage cage

This project was copied into this VM by acage. The person you work for gets
your work back with `acage pull`, which fetches the **commits** on the
checked-out branch, for them to review before anything is pushed.

- Commit your work as you go, in small commits with clear messages.
  Uncommitted changes are not pulled.
- Don't push anywhere. There are no git credentials here; the person reviews
  your commits and pushes them.
- The dev server may be running in the tmux session `preview`
  (`tmux attach -t preview`, detach with Ctrl-b d). Its port is forwarded to
  the person's browser, so they see your saved changes live.
