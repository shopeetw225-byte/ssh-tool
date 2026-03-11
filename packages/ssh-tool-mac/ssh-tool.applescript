property urlScheme : "ssh-tool"
property maxMinutes : 1440

on run
  my openControlPage()
end run

on open location thisURL
  try
    my handleURL(thisURL)
  on error errMsg number errNum
    display dialog ("SSH Tool error (" & errNum & "):" & return & errMsg) buttons {"OK"} default button "OK"
  end try
end open location

on handleURL(u)
  set rest to my stripPrefix(u, urlScheme & "://")
  if rest is "" then
    my openControlPage()
    return
  end if

  set actionPart to rest
  set queryPart to ""
  if rest contains "?" then
    set qpos to offset of "?" in rest
    set actionPart to text 1 thru (qpos - 1) of rest
    set queryPart to text (qpos + 1) thru -1 of rest
  end if

  if actionPart contains "/" then
    set spos to offset of "/" in actionPart
    set actionPart to text 1 thru (spos - 1) of actionPart
  end if

  if actionPart is "start" then
    set minutesRaw to my queryParam(queryPart, "minutes", "60")
    set minutes to my toInt(minutesRaw, 60)
    if minutes < 1 then set minutes to 60
    if minutes > maxMinutes then set minutes to maxMinutes
    my runAsAdminWithEnv("SSH_TOOL_MINUTES", minutes, "start")
  else if actionPart is "stop" then
    my runAsAdmin("stop")
  else if actionPart is "recover" then
    my runAsAdmin("recover")
  else if actionPart is "status" then
    set out to my run("status")
    if out is "" then set out to "No output."
    display dialog out buttons {"OK"} default button "OK"
  else
    my openControlPage()
  end if
end handleURL

on openControlPage()
  set controlPath to my resourcePath("ssh-tool-mac/control.html")
  do shell script "/usr/bin/open " & quoted form of controlPath
end openControlPage

on resourcePath(rel)
  set appPath to POSIX path of (path to me)
  return appPath & "Contents/Resources/" & rel
end resourcePath

on scriptPath()
  return my resourcePath("ssh-tool-mac/remote-support.sh")
end scriptPath

on run(action)
  return do shell script (quoted form of my scriptPath() & " " & action)
end run

on runAsAdmin(action)
  do shell script (quoted form of my scriptPath() & " " & action) with administrator privileges
end runAsAdmin

on runAsAdminWithEnv(k, v, action)
  set cmd to k & "=" & (v as string) & " " & quoted form of my scriptPath() & " " & action
  do shell script cmd with administrator privileges
end runAsAdminWithEnv

on stripPrefix(s, p)
  if s starts with p then
    return text ((length of p) + 1) thru -1 of s
  end if
  return s
end stripPrefix

on queryParam(q, k, def)
  if q is "" then return def
  set pairs to my splitText(q, "&")
  repeat with pair in pairs
    set p to pair as string
    if p starts with (k & "=") then
      return text ((length of k) + 2) thru -1 of p
    end if
  end repeat
  return def
end queryParam

on splitText(t, delim)
  set oldDelims to AppleScript's text item delimiters
  set AppleScript's text item delimiters to delim
  set parts to text items of t
  set AppleScript's text item delimiters to oldDelims
  return parts
end splitText

on toInt(s, def)
  try
    return s as integer
  on error
    return def
  end try
end toInt

