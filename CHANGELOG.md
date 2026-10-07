# Changelog

[← back to the README](README.md)

## 1.7.1

**Update from 1.7.0 if you have it, and do not press *Remove duplicates* there.**
In 1.7.0 that button could delete real contacts. This release fixes it, makes it
save the whole address book before it deletes anything, and makes it check
its own work afterwards and put back anything that should not have gone. And
contacts can now be copied from one phone to another.

### Copy contacts to another phone

*Copy to another phone...* on the Contacts page of both windows writes this
phone's contacts on another connected one, in one run of the writer: seconds,
and no tap on either phone. With two phones connected it names the other; with
more it asks which. **Skip ones it already has**, ticked to start with, leaves
out a contact the other phone already has (the same name and number);
unticked, every contact is copied, so those are there twice.

Only the address book goes - Google accounts and the phone's own contacts, not
WhatsApp, Telegram or SIM entries - a contact's numbers stay one contact, and
nothing is deleted on either phone. They land where the other phone puts a new
contact: measured, a Redmi keeps them on the phone and a vivo puts them in its
default Google account, which Google then puts on every phone signed in to it.
The question before it starts says so.

### Remove duplicates deleted real contacts - fixed, and it keeps a copy now

**If you used *Remove duplicates* in 1.7.0, contacts may be missing.** It
treated WhatsApp's, Telegram's and Meet's own entries for a person as copies of
that person's real contact, kept whichever was oldest, and deleted the rest -
often the real Google contact, with the WhatsApp entry left behind. Google then
deleted it on every phone on that account, and WhatsApp dropped its own entry
too once the number had left the address book. Measured on two phones: 277 and
330 contacts gone. The dry run before it said nothing would be lost, because it
counted the WhatsApp entries as the copies that stayed.

To get them back: Google Contacts keeps what was deleted for 30 days
(*contacts.google.com > Settings > Undo changes*), and any backup the Backup
page has can put its contacts back.

What *Remove duplicates* does now:

* It looks only at the address book itself - Google accounts and the phone's
  own contacts. WhatsApp, Telegram, Meet, SIM and any account it does not know
  are never deleted and never count as the copy that stays.
* A copy counts only inside one account: the same person in Google and in the
  phone's own contacts is not a duplicate.
* A contact holding anything besides a name and numbers - an email, a photo, a
  note with text in it, a birthday - is never deleted. (Google keeps an empty
  note and nickname on every contact; empty ones do not count.)
* What it deletes is first saved as a backup beside your others, named
  *removed duplicates*. The Backup page opens it and *Restore contacts* puts it
  back, into the Google account each contact came from. If that copy cannot be
  written, nothing is deleted.
* Putting contacts back now skips one only when the address book has it - not
  when only a WhatsApp entry has the same name and number.

And it checks its own work. Before deleting it saves the **whole** address
book, not only what it means to remove - what went wrong the first time was
what went *with* the copies. After deleting it reads the phone again: every
name and number the address book had must still be in it, and anything
missing is put back from that backup at once, with the log saying so. Tried on
a real phone with test contacts, deleting one by hand in the middle to stand
for the WhatsApp chain: the check found it and put it back, the copies went,
the contact with an email and the app entries stayed, and the 1,815 other
numbers on the phone were exactly as before. A contact put back keeps its
numbers together as one contact.


**Everything a backup takes now goes back.** Messages and the call log join
the contacts, the files and the apps, in minutes rather than hours; Nova's
backup page has a tab for each of them and one button for all; and the
Contacts page can clear out what is on the phone twice.

### A backup now goes back whole

A backup took contacts, messages and the call log, and only the contacts went
back: the messages and calls were "read-only, because adb cannot write them".
That was said without being tried. Tried on the test phone, adb's shell **can**
write the call log, and it can write messages once it allows itself to (the
shell's `WRITE_SMS` app-op is `ignore`, and the shell may change its own). Both
now go back, from both windows, and *Restore everything* includes them.

The second problem was time. `content insert` is a shell script that starts a
whole Java runtime for each row, about 1.5 s, which is nine hours for a phone's
call log. So the rows go through a small writer instead (`android\restore`),
run once by `app_process` the way the FTP server is, which hands the provider
the whole file. Measured on a phone with 16,414 calls and 5,329 messages: 417 s
and 416 s. A run twice adds nothing the second time - what the phone has (same
number, time and kind) is left alone - and the calls go back read, so no old
call rings a missed-call notice. The message permission is put back as it was
after the run, whatever happens.

Contacts go through the same writer: into the phone's own contacts in seconds,
with nothing to tap. The other way stays, for contacts meant for a Google
account: one vCard file and the phone's own import screen. On the test phone the
writer found three contacts that import had merged away.

### The backup page, one tab per kind

Nova's backup page has a tab for each kind - *Contacts*, *Messages and calls*,
*Files*, *Apps* - each showing what the backup holds and carrying its own
button. Opening a backup brings up **Restore everything**, which says what it
will put back before it does. A backup of a second space keeps its contacts
under `users\<id>\`, and the restore looked only in `personal\`: a backup whose
own header said 927 contacts was answered "this backup holds no contacts".

### Smaller things

* **Remove duplicates, on the Contacts page of both windows.** It finds a
  contact that is a copy of another (same name, same number, spaces and dashes
  aside) and a number saved twice inside one contact, says how many, and
  deletes them after you say yes. A contact goes only when every number it has
  stays on another one. Worked out, without deleting anything, on a phone with
  943 numbers: 66 copies and 215 doubled numbers would go, leaving 629 -
  exactly the 629 different ones it had.
* **Deleting contacts is one call per hundred, and can be stopped.** Deleting
  every contact was one `content delete` - a Java runtime - per contact. Now
  the ids go in batches (`_id IN (...)`), and the busy strip has a **Cancel**.
* **A dialog no taller than the screen.** The delete question listed every
  contact picked, and grew past the bottom of the screen with its buttons. The
  list now scrolls inside a box at most 60% of the screen high.
* **The right-click menu said `System.Windows.Controls.StackPanel`.** Its first
  entry was named from a button whose content is an icon and words; the words
  are read out of it now.
* **Mirror in the header works from the start.** It was wired by the Mirroring
  page, which is built when first opened, so until then it did nothing. The
  window wires its own controls now, and an audit fails any page that does.
* **The version is checked in both windows** against this file's newest
  heading: the title, the log line, the splash and Nova's side panel.

## 1.6.1

**Nothing in either window changes.** What this ships is 1.6.0 with its version
number moved on; both commits behind it are about the repository rather than the
tool. It is here so that the two are recorded somewhere a person can find them.

* **The editor's own folder is ignored.** `.idea/` sat untracked in every
  `git status`, one line of noise over anything real that was waiting there.
* **CI checks out with an action that asks for the runtime it gets.**
  `actions/checkout@v4` declares Node 20, which the runners no longer carry, so
  every run was forced onto Node 24 and wrote a deprecation notice into its own
  annotations. `@v7` declares Node 24. Measured either side of the change: the
  run before it carried that warning, the run after carried no annotations at
  all. v5, v6 and v7 all declare Node 24, and the newest was taken after
  reading what the two majors in between changed - v6 keeps the git credential
  in a separate file, v7 refuses to check out a fork's head for
  `pull_request_target` and `workflow_run` - neither of which this workflow
  uses, and nothing in it reads the token after the checkout.

## 1.6.0

### "The phone took it" - when the phone had not

Pressing *Factory reset* said **the phone is erasing itself and will restart as
new**, and the phone did nothing at all. The reset went out as a broadcast, and
`Broadcast completed: result=0` was read as the phone agreeing to it. It is not:
it means the message was delivered. Android's receiver is in the system, and a
system that does not like the caller drops it without a word back down the
cable.

Now the phone is asked first and checked afterwards.

* **Asked first**: `dumpsys package com.android.shell` says whether adb's shell
  holds `MASTER_CLEAR`, which is what Android looks at. Where it does not - the
  phone this was tested on grants its shell 1046 permissions and this is not
  one of them - the broadcast is not sent at all, and the phone's own reset
  screen is opened, which is the way that works.
* **Checked afterwards**: a phone that has really begun erasing itself leaves
  the cable within seconds, because it restarts to do the wiping. One that
  ignored the broadcast goes on answering. That is the only honest evidence
  there is, so it is what the window is told - *the phone is still here, so it
  did not act on it, whatever the broadcast reported*.

Writing the test for it caught a second fault in the new code: the wait minded
a leftover "stopped" flag before it asked the phone anything, so a phone that
was never asked would have been reported as not having gone.

**And the screen it falls back to is tried properly.** The phone's own reset
screen wants `MASTER_CLEAR` to be *opened*, not only to do the resetting, so
on such a phone that failed too - and the window gave up there, after writing
Android's eighteen-line Java stack into the activity log one red line at a
time. Now every screen in the list is tried in turn until one opens, the
refusal is one line that names the permission, and a screen that is not the
reset screen itself is said to be so rather than left looking like the place
to tap.

### Nova opens about twice as fast

The splash said what was happening; this makes there be less of it. Measured
before anything was written: building the eighteen pages was three of the six
seconds the window took, and it was not the XAML - 2 to 19 ms a page - but
PowerShell reading each page's script and building its controls.

**A page is now built when it is first opened.** What goes in the side
navigation - a page's name, glyph and section - is read off its own
`Register-Page` line as text, without running the file, so the navigation is
whole from the start and nothing about using the window changes. Opening a page
for the first time costs the 50-400 ms that page always cost.

* **Pages call each other** - the Overview page's buttons alone reach into five
  others - so a call to a name that belongs to a page nobody has opened builds
  that page and goes through, rather than failing. Which name belongs to which
  page is read at startup from the same files.
* **Three pages are still built at the start**, because the window itself
  reaches into them: the FTP and clipboard pills in the header, and the rule
  count on the Automation item.
* **The tests get every page at once**, the way it used to be for everyone,
  because they call into pages without opening them. One test is run the way a
  person gets it, and opens all eighteen one after another.
* `audit.ps1` fails the build if a page stops saying what it is in a shape that
  can be read without running it - otherwise it would quietly lose its place in
  the navigation.

Measured back to back on the same machine, three times each: 7.2 s against
3.9, 15.0 against 5.4, 7.4 against 3.4.

### A copy the phone made, written down as a copy this PC sent

Found by running the clipboard test against the phone with a mirroring window
open, which is how anyone would really use the two together.

**scrcpy carries the clipboard over by itself.** Measured: what was copied on
the phone was on this PC within half a second, before the watch's turn came
round at all - and with no sharing running at all, so it is scrcpy's doing and
not this program's. The watch then found this PC holding something new, called
the phone's own copy a thing this PC had sent, wrote it back onto the phone for
nothing, and the monitor showed the wrong direction for it. Now a copy that is
on this PC already when the phone's changes is written down as **phone -> PC**,
marked `mirror`, and nothing goes back the other way.

**And a copy is remembered only once it has really landed.** Another program
can hold this PC's clipboard open for the moment we ask for it - the code says
so in as many words a line above - and what the phone had copied was being
remembered before the write was tried. When the write lost that race the text
was remembered all the same, so the next turn saw nothing new and that copy
never arrived: one lost in silence, which is exactly how sharing looks when it
looks broken. The turn after now tries again, and the log says once that
something else is holding the clipboard.

**A test that passed was reported as not having finished.** `Get-Content` opens
a file so that nobody may write to it while it reads, and the runner reads each
test's report every half second for the whole of its life. The test's own `Say`
gave up after a second on the line it could not add - and the line it dropped
was `TEST DONE`. The encoding test, which had passed every check in 23 seconds,
was called *did not finish*, and the runner then sat out its whole five-minute
timeout waiting for a line that was never coming. Both sides now share the
file: the report is appended through a stream that allows reading, and read
through one that allows writing.

## 1.5.1

### Something on screen while it opens

Both windows take seconds to build and showed nothing at all until they were
ready. Measured: the classic window 3.5 s before it appears (2.1 s of that is
building its 530 controls), Nova 6.3 s, of which 5 s is reading its eighteen
pages.

A small window now appears about a third of a second in - the program's icon,
its version, a bar and a line saying what is happening: *Building the
mirroring page ...*, *Loading the contacts page ...*, *Looking for adb, scrcpy
and gnirehtet ...*. Nova names every page as it reads it.

* **The bar is moved along measured steps**, not spun. It says how far along
  this really is, because the steps are the ones that were timed.
* **It costs nothing worth measuring**: run against the same file with it
  turned off, the difference is smaller than the difference between two runs.
* **Nothing to wait for, no splash**: a window starting minimized with Windows
  gets none, and neither do the test runners.
* It is drawn with WinForms in both windows, because Nova loads WinForms
  anyway and starting WPF is part of what is being waited for.

## 1.5.0

### What a backup can have done to it is on the right mouse button

Two rows of buttons under the backups list, and two of them said *Show in Explorer* - one for
the backup picked in the list, one for the backup that is open. Renaming the second one was not
the answer.

**Right-click a backup in the list** for *Open this one*, *Show in Explorer*, *Continue /
update* and *Delete ...*; those three come off the row of buttons, in both windows. *Refresh*
and *Open this one* stay as buttons, and a double-click still opens one. The menu is greyed
while a backup or a restore is running, exactly as the buttons were.

### The classic window says what the phone is, and what it is doing

Every one of these was asked for against a picture of Nova, and the classic window had none of
them. Both windows now read the same two things out of `shared\DeviceFacts.ps1`.

* **The square beside the status line is the make of the phone**: a letter in the make's own
  colour for the sixteen this knows, and the plain phone glyph for one it does not. It goes by
  what the phone says it is made by, because a model code like `23108RN04Y` says nothing - that
  answer comes back in the same trip as the Android version, so it costs nothing extra.
* **A second line under it says what the phone is doing with itself**: CPU, RAM and GPU, each
  coloured by its own number - quiet below 70%, orange from 70, red from 90. Read every six
  seconds on a timer of its own, and never while something else is using adb. Most phones will
  not let adb read the GPU at all, and then it says *not readable*.
* **The clipboard is at the right of that line**: *clipboard off* or *clipboard on*. Click it
  for the page, right-click it to start or stop sharing - the same two meanings Nova's pill has.

### A backup says how much has come over, and how long it has taken

The line under the bar guessed at what was left and said nothing else. It now carries the whole
story: **1.2 GB of 4.0 GB, 2.8 GB to go  -  4 min gone, about 9 minutes left, done by 6:52 AM**.
A run that counts apps rather than bytes says *7 of 20, 13 to go* instead of reading a count of
apps out as if it were a number of bytes.


### The shared clipboard now actually crosses

It did not. Turning sharing on and copying something went nowhere in either direction, and the
reason was not Android being strict - it was this asking the wrong user.

* **The clipboard belongs to the user in front.** A phone in its second space runs as another
  user, and user 0's clipboard is both empty and unreadable from there - which looks exactly
  like a phone that refuses, and was read that way. Every question now starts with
  `am get-current-user`. Switching spaces while sharing is on means stopping and starting it.
* **It goes through the phone's own clipboard service**, both ways:
  `service call clipboard` for `getPrimaryClip` and `setPrimaryClip`. That takes a ClipData
  parcel, and the service tool can only write a parcel as a run of 32-bit words, so the parcel
  is built here word by word - in a shape read off the phone rather than guessed. Because that
  shape differs between Android versions, a parcel this reads teaches it the shape to write, and
  **a write is never believed until it has been read back**.
* **scrcpy is now the last resort, not the first.** Its clipboard listener never fired once on
  the phone this was written against, for either user, so what the page used to wait for was
  never coming. `cmd clipboard` is tried first and is almost never there: it is not in AOSP.
* **A long clipboard is carried too.** A few thousand characters become a few thousand words of
  command, and Windows stops a command line at 32767 characters: the line now goes down adb's
  own input instead. Twenty thousand characters crossed in testing, and past 64 KB it says so
  rather than sending half.
* **Text only, and it says so.** A copied picture or file is a `content://` link that means
  nothing off the phone. Copy one and the list names the kind - *image/png* - and points at the
  file pages, instead of going quiet as though nothing had been copied.

Measured on the phone itself, both ways, with awkward text - Arabic, newlines, quotes, `&`,
`$x` - and with the phone's own clipboard saved and put back byte for byte afterwards.

### The Nova window says more about the phone, and about itself

* **The square beside the phone's name is its make**: a letter in the make's own colour for the
  sixteen this knows - Samsung, Xiaomi, Google, OnePlus, Huawei, Oppo, vivo, Motorola and the
  rest - and the plain phone glyph for a make nobody here knows. There are no brand marks to
  show: the icon font has none, and shipping somebody's logo with this is not a small thing.
* **What the phone is doing with itself**, at the foot of the side bar and from every page:
  whether its screen is on and locked, how busy its processors are (`dumpsys cpuinfo`), how much
  of its memory is in use (`/proc/meminfo`), and its GPU where Android lets adb read it at all -
  which on the phone this was measured on it does not, so it says *not readable* rather than
  looking broken. The screen line costs nothing: it is the reading the header pill already made.
* **The clipboard has a pill in the header** beside the FTP one: click it for the page,
  right-click it to start or stop sharing.
* **The logo is a button**: it opens Overview, and pressing it there again reads the page over.
  It shows the program's own icon when the assets folder is beside the script.

### The clipboard, shared with the phone

A page of its own in both windows: turn it on, and what you copy on the phone arrives on this
PC while what you copy here goes to the phone. A list shows everything that moved - the time,
the phone, which way, how, how many characters and the text.

* **Each phone is asked which way it can go**, and the page says what it answered. Android has
  let only the app in front touch the clipboard since Android 10, so there are two doors:
  `cmd clipboard`, which some ROMs implement and which gives both directions over adb alone,
  and scrcpy, whose server passes the phone's clipboard on while it is connected - started here
  with no window, no video and no audio, a control connection and nothing else.
* **What cannot be done is said, not faked.** Where Android will not let adb set the clipboard,
  the text can be typed into whatever has the cursor instead, and that line in the list says
  `typed`. Where there is no route at all, turning sharing on says so.
* **Nothing is bounced**: what came from the phone is not sent back to it, and the same text is
  never sent twice. The first turn after switching on only learns what is already here, so
  something copied beforehand is not pushed to a phone by surprise.
* **What was copied stays in the window.** The activity log is told the length only - a log can
  be saved to a file, and a clipboard can hold a password - and the list goes when the window
  closes, along with the connection it opened.

### A backup can be of any user on the phone, or of all of them

A phone can have more than one person on it, and Android keeps each one's files apart. Until
now a backup was always the owner's, without saying so. The *Back up* box now says who the
phone has and lets you pick: the main user, one of the others on its own, or everyone adb can
read.

* **What cannot be read is marked, not hidden.** Each user's storage is tried before the box is
  filled - measured on a phone with three users, where the owner's files and the clone
  profile's could be read and a stopped guest's could not - and a user whose files are shut is
  offered as *(no files to read)*, because their app list, settings and contacts can still be
  taken. The line beside the box names them; the log says which user was skipped and why.
* **The owner's things stay where they were**: `files\`, `personal\`, `settings\`. Every backup
  taken before this opens, restores and carries on exactly as it did. Anyone else goes into
  `users\<id>\` beside them, *What is inside* says *Files (user 999)* against their files, and
  a restore sends each user's files back to that same user - or counts them out, in words, if
  that user is not on the phone any more.
* **Each app says which users have it.** `pm list packages --user <id>` answers even for a user
  whose files are shut, and an APK belongs to the phone rather than to a user, so it is still
  fetched once.
* **What is not per user is taken once and said so.** Messages and the call log have
  `singleUser` providers: Android shows every user the same ones - measured, where user 0 and
  user 10 both answered with the same 8440 rows - so they are taken once instead of being
  written into every user's folder. Contacts *are* per user, and are taken per user.

### A factory reset, and a memory card formatted

Two buttons at the bottom of *Advanced > Device tools*, for any Android phone. Both ask twice -
a question saying what will go, then the word `FORMAT` typed out - and neither runs while a
backup or a restore is running.

* **Factory reset** puts the phone back to how it left the factory. The question also says what
  backup of *that* phone this PC has and how old it is. Then: the phone is asked to erase itself
  with the `FACTORY_RESET` broadcast and, where Android refuses it - adb's shell does not hold
  `MASTER_CLEAR`, which is how it should be - the phone's own reset screen is opened and the
  last tap happens on the phone. The log says which of the two it was.
* **Format the memory** hands the card to Android's own storage manager (`sm format`), which
  unmounts it, writes a new empty filesystem and mounts it again. This one adb really is
  allowed to do: `dumpsys package com.android.shell` says `MOUNT_FORMAT_FILESYSTEMS:
  granted=true`. The card comes back under a new serial, and the page says where it is now.
* Where a ROM refuses even that, it offers to **delete every file on the card** instead, which
  needs no permission adb does not already have. With **no card in the phone**, it offers to
  empty the phone's own storage - everything under `/sdcard` - leaving apps and settings alone.
* Emptying goes name by name from the top level, so the log says what went, **Cancel** is
  answered between names, and what the phone would not let go is counted and named rather than
  passed over.
* Nothing is claimed unread: a format is checked by reading the volume back and counting the
  files on it, an erase by counting what is left. A card is also found on a ROM without `sm`,
  including the sixteen-hex-digit name an exFAT card gets - measured on one.

### A backup can be named, deleted, brought up to date - and takes less time

* **Call it what you like**: a name box beside the parts. It goes into the file's name and into
  the backup, so the list shows it later; without one, the phone and the time still name it.
* **Delete ...** in *My backups* removes a backup from this PC after asking. It will only delete
  something that really is a backup, so a mistyped folder of photos is safe.
* **Pack into one .zip is now a choice** (on by default). Packing reads and writes everything a
  second time - measured at about 40% on top of the pull - so turning it off is the quickest
  way to a faster backup, and a backup kept as a folder can be brought up to date later.
* **Continue / update**: the button that carries a stopped backup on now also refreshes a
  finished one. Same work, same comparing - only what is new or changed on the phone comes
  over, which on a second backup is minutes instead of an hour.
* **A folder adb gave up on is mended.** adb abandons a whole folder when one name defeats it -
  measured on a folder named in Arabic-Indic digits, where it wrote *cannot create ... Not a
  directory* and left the rest behind, quietly. The files it missed are now fetched one at a
  time into folders made here, and the log says so.
* **Every app's APK is found in a few calls** instead of two per app: `pm list packages -f`
  names them all at once, and one `ls` over their folders finds the splits. Measured at 0.46 s
  per app before, 74 seconds of asking on a phone with 163 apps.
* **Times are written the way a clock is read**: `2026-10-02 03:22:36 PM`, in the backups list,
  in what a backup says about itself, in *done by 5:15 PM*, and in both windows' logs.

### A backup can hold the memory card, is carried on where it stopped, and says how long it needs

* **How long is left, in words**: *Files: DCIM  -  about 17 minutes left, done by 15:16*. It is
  on every line a backup writes - pulling, packing, putting one back, carrying one on - and
  comes from what has been done over the time it took, so it settles as it goes. Nothing is
  claimed in the first seconds, when a guess would be wild.
* To have something to count against, the folders on the phone are measured before anything is
  pulled (one `du` each, which the backup asked for anyway, only later). Restoring needs no
  measuring: a backup already knows how big every file in it is.

* **The memory card is a part of its own**, ticked or not like the other four. It is **off by
  default**, because a card can hold more than the phone does. Each card's files go under its
  own name (`card/1A2B-3C4D/...`), so two cards never mix, and putting them back sends them to
  the card in the phone at that moment - whatever that one is called. With no card in the
  phone, the files that came off one are counted and left, and the log says so.
* **A backup that stopped can be carried on.** *My backups* marks it *stopped part way*;
  **Continue this one** asks the phone what it holds and how big each file is, reads the folder
  for what came over, and fetches only the difference - a file cut off halfway is fetched
  again, one that arrived whole is left alone. Apps already fetched whole are skipped by
  comparing their APK sizes with the phone's. Then it is packed like any other backup.
* Nothing from the interrupted run is needed to carry it on - no notes, no half state - so it
  works after the program has been closed and opened again, or days later. It only refuses to
  carry a backup of one phone on with another phone plugged in.

## 1.4.0

### Phone FTP controls

* FTP has its own page in Classic and Nova. The default login is `pc` / `123`; it and the port are editable, and new random credentials can be generated. FTP can be opened in Windows File Explorer.
* Closing AndroidDC leaves the phone server running. Reopening detects it, restores the login on the same Windows account, and Nova shows a header indicator while it runs.
* Nova's FTP header indicator shows running or off; click it to open FTP, or right-click and confirm starting or stopping the server.
* The existing AndroidDC icon beside the Windows clock now has an FTP menu showing the selected phone's status and actions to open the page or confirm starting or stopping the server.
* The selected phone gets a small AndroidDC FTP notification app only when FTP starts. Its **Stop FTP** action ends sharing; **Uninstall FTP phone app** in AndroidDC removes the app and temporary FTP files without deleting uploaded user files.

### A backup is one file, and you can see what is in it

* **A backup is a `.zip` now**, not a folder: one file named after the phone and the time, to
  copy, to move, or to put on another drive. The files are still pulled into a folder first -
  that is what adb writes - and the folder is packed and then removed. Photos, video and APKs
  go in as they are rather than being squeezed again, so packing costs minutes, not hours.
* **Restoring reads the `.zip`.** Nothing is unpacked whole: each file is taken out, sent to
  the phone, and dropped again, and an app's APKs come out one app at a time.
* **What is inside** lists every file in the opened backup - which part it belongs to, where it
  was on the phone, how big it is - read from the zip's own index, with a find box over it.
  Pick some lines and *Save a copy ...* writes those files onto this PC: one photo out of a
  backup, with no phone in it at all.
* **My backups** shows one folder - the box at the top says which, *Browse ...* changes it, and
  it starts at wherever your last backup went. The list under it is what is in that folder at
  this moment, newest first: when, which phone, what it holds, its size and the file's name.
  Nothing is remembered about the backups themselves, so one moved into that folder appears and
  one taken out of it is gone, with no list to tidy. Both windows follow the same folder, kept
  in `%APPDATA%\AndroidDCackups.json`.
* **Opening a backup is quick whatever is in it**: the manifest is read and nothing more, so a
  backup of forty thousand photos names its phone at once. *What is inside* and *Apps to
  install* read the backup itself, and only when you look at them, with the bar rolling and a
  count while they do. A backup of six thousand files opened in 39 ms and listed in 1.4 s where
  it used to freeze the window for minutes: an array that grows by `+=` copies itself every
  time, and a phone's worth of files made that thousands of copies.
* **Older backups still open.** A backup kept as a folder - one taken before this, or one whose
  packing was cancelled - opens with *From a folder ...* and behaves the same everywhere.
* Cancel works while it packs, and a stopped pack leaves no half-written `.zip` behind: the
  pulled folder is kept. A drive without room for the packed copy says so and keeps the folder
  as well.
* **The apps in a backup are a list you can read**: what each app is called, its package, the
  version the backup holds, its size, and how it stands against the phone - *not on the phone*,
  *on the phone*, *older on the phone*, *newer on the phone*. The ones the phone lacks come
  first and are ticked for you, the line under the list says how many and which button to press,
  and a find box narrows it by name or package while the ticks stay put. "missing" is gone: it
  said nothing about what to do.
* **A backup writes down what its apps are called**, from `scrcpy --list-apps`, while the phone
  still has them - so a backup read a year later says *WhatsApp*, not `com.whatsapp`, even for
  an app that phone no longer has. Backups taken before this show packages.
* A refused install says what to do: a newer version on the phone has to be removed before an
  older one goes on, and an app signed by someone else has to be removed with its data.
* Smaller things found on the way: a list with no room for its "nothing here yet" line hides it
  instead of leaving it where it last stood, on top of the row above; Nova's Backup page scrolls
  when the window is too short for it, rather than cutting the buttons off the bottom; and the
  bar rolls, instead of sitting at zero, while something is running whose length is not known.
* Two bugs found while doing it: the list of contacts in a backup was read back as one item
  when it held several (so restoring several contacts would have made one), and a JSON list
  read with `@(... | ConvertFrom-Json)` came back as a list of one array.

### The classic window, made easier to live with

* **It opens where you left it**, at the size you left it, maximized if it was. A saved place
  is used only while it still lands on a screen this PC has, so a window cannot come back onto
  a monitor that has been unplugged.
* **Every button says what it does on hover.** 125 of the 190 had nothing; now all of them do,
  and they say what the button acts on, what the phone may refuse, and the key that does the
  same. A test fails if a button ever ships without it.
* **An empty list says which button fills it** instead of sitting there blank - the device
  list, apps, files, contacts, messages, processes, Wi-Fi, Bluetooth, users, the automation
  rules and a backup's apps.
* **The log has a find box.** Type in it and only the lines holding that text are shown; empty
  it and they all come back. The lines themselves are kept either way, and *Clear log* (Ctrl+L)
  empties both.
* **The keyboard reaches more.** `Ctrl`+`0` opens the tenth tab and `Ctrl`+`Shift`+`1`...`9`
  the ones after it, so every tab has a key. `Enter` does the page's reading action - refresh
  the list, go to the folder - and never anything that starts, installs, deletes or sends.
  `Tab` now walks a page the way the page is laid out, down and across, instead of in the
  order the controls happened to be written.
* **The device list's `Client` column is called `gnirehtet`**, which is what it is about.
* **The Connection box on Device tools was twelve controls deep.** The three that are only
  reached for when something is stuck - list reverse tunnels, kill stray relays, repair
  tunnel - are their own box now, *When something is stuck*.
* **Shorter tab captions**: *Mirroring*, *More options*, *Device tools*, *PC -> Phone*,
  *Phone -> PC*. The words in brackets repeated what each page says in its first line, and the
  strip was the first thing to run out of room on a small window.
* Reading several phones at once says which phone of how many in the busy strip.

## 1.3.0

### A backup of the phone, and putting one back

* **Advanced > Backup** in the classic window, the **Backup** page in Nova. Tick what goes in -
  phone files, the apps' APK files, contacts with messages and the call log, the settings and
  app list - choose a folder, and it writes one folder per backup, named after the phone and
  the time, with `manifest.json` saying what is in it. Plain files: no archive, no password,
  nothing to unpack.
* **What cannot be in it, and why.** Android does not let adb read what is inside an app -
  chats, game saves, an app's own settings - without root, and `adb backup` has returned almost
  nothing since Android 12. `Android/data` and `Android/obb` are closed for the same reason;
  `Android/media`, where messaging apps keep pictures, is taken.
* **Putting it back**: open a backup and the window says what it holds. *Restore files* asks
  first when the phone already has some of them - write over them, send only the rest, or stop.
  Apps are listed with the ones this phone lacks ticked, and each is installed in one call,
  splits included. *Restore contacts* adds the ones the phone does not have, matched by name
  and number; messages and the call log are saved to read but never written back, because
  Android has no way for adb to write them.
* **It can be stopped, and it says what happened.** A **Cancel** button next to the progress
  bar stops a backup or a restore where it is - adb is killed mid-file, and what was already
  done stays. The bar fills as a folder is pulled, named and sized, because the size of the
  folder on the phone is read first. A phone that is unplugged halfway is noticed at once and
  the run ends there rather than failing file after file. Whatever ends it - finished,
  cancelled, or the phone gone - the log says so and a notification appears by the clock, and
  a backup that did not finish is marked *not complete* in its manifest and where it is opened.
* `tests/backup.ps1` and `nova/tests/backup.ps1` check the parts, the folder name, the row
  parser, a backup folder read back and which files a phone already has - against a made-up
  phone, so nothing is sent to a real one.

## 1.2.2

* **`start-menu.vbs`** puts both windows in the Start menu: *AndroidDC* and *AndroidDC Nova*,
  with the AndroidDC icon, under *All apps*. Windows keeps *Pin to Start* for the user, so the
  message it ends with says where that is. Run it again after moving the folder. CI checks it
  points at both launchers.
* **`start-menu-remove.vbs`** does the reverse: it removes those two shortcuts and touches
  nothing else. `start-menu.vbs /remove` does the same. Both, their switches and their
  messages are in *Command line*.
* **Nova no longer jumps to Overview.** A double-click on a phone in the device list opened
  Overview from whatever page was on screen; it now only picks the phone and closes the list.
  *Load details* on Overview still reads the phone there.
* **Nova remembers its page at once.** The page on screen was written only when the window
  closed normally, so a window Windows ended at sign-out - one in the tray, say - opened again
  on an older page. It is now written each time the page changes.

## 1.2.1

### The rules set before, seen without looking for them

* At startup the log says what is set: how many rules, how many are on, each rule's phone
  and actions, whether AndroidDC starts with Windows, and where that is set.
* The icon by the clock has an **Automation** entry at the top of its menu. It lists the same
  thing, read from the rules file each time the menu opens, so a change made in the other
  window shows too. A click on a rule, or on *Open the rules ...*, shows the window at the
  rules page. The icon's tooltip counts the rules that are on.
* The classic *Advanced > Automation* tab and Nova's *Automation* entry in the side navigation
  carry the number of rules, e.g. **Automation (2)**.

### Documentation

* Every page caught up with 1.2: `-Minimized` in the command line, start with Windows and the
  icon by the clock in getting started, rules in *What it runs on your phone*, three new
  troubleshooting sections (a rule that did not run, the icon out of sight, not starting with
  Windows), the shared folder and four new PowerShell traps in the architecture, and the icon's
  clicks in *Keyboard and mouse*.

## 1.2.0

### Automation, in both windows

* **Start with Windows**: AndroidDC can start when you sign in, minimized, in the classic window
  or in Nova. It is one value under your own Run key (`HKCU\...\Run`, named `AndroidDC`),
  pointing at the launcher with `-Minimized`; switching it off removes that value and nothing
  else.
* **Rules per phone**: pick a phone, switch on what should happen when it is plugged in - share
  the phone's internet with the PC (USB tethering), share the PC's with the phone, the adb
  proxy, the hotspot, adb over Wi-Fi, mirroring, a camera, the phone's sound, a screenshot,
  waking the screen, Wi-Fi / Bluetooth / NFC, stay awake, auto-rotate, location, battery saver,
  vibrate, open an app, logcat, a Windows notification. The actions run in that order, on that
  phone only, one after another, and **Run now** tries a rule without unplugging.
* The rules are kept in `%APPDATA%\AndroidDC\automation.json` and written at once, so both
  windows see the same rules. Only one window runs them at a time. A window opened by hand, or
  by the other window's switch button, does not run the rules again for phones that were
  already plugged in; a window started with Windows does.
* Classic: **Advanced > Automation**. Nova: the **Automation** page under System.
* **An icon by the clock** while AndroidDC runs, in both windows. A click on it hides the window
  or shows it again; its menu has *Show the window*, *Hide to the tray* and *Exit*. Minimizing
  hides the window there too - off the taskbar, still watching for phones and running their
  rules - and a window started with Windows starts there. The first time it hides, a
  notification says it is still running. The close button still closes the program.
* The device list now follows the cable while the window is minimized or behind other windows
  too - still not while one of its own questions is waiting.
* Both launchers pass their arguments on to the script.
* `tests/automation.ps1` and `nova/tests/automation.ps1`: the rules file (a one-rule list stays a
  list, a broken file is not overwritten), plugged in versus already there, the start-up entry
  against a test key - the real Run key and rules are never touched.

## 1.1.0

### A second window: Nova

* **AndroidDC Nova** (`androiddc-nova.vbs`, the code in `nova/`) is the same tool in a newer
  design: a side navigation grouped into Workspace, Personal, Connect and System, a device card
  with battery, signal and screen, a card per task, and an activity log that can be dragged or
  folded. It is WPF hosted in Windows PowerShell 5.1 - still nothing to install.
* Every feature of the classic window is there, page by page: Overview (battery, temperature
  and memory, quick toggles that show the phone's state, phone number), Screen, Mirroring,
  Apps, Files, Camera & mic, Messages, Contacts, Tethering, Radios, Tools, Running, Users and
  Shell. `F5`, `Ctrl`+`1`...`9` and `Ctrl`+`L` work there too.
* The two windows share the project's adb, scrcpy and gnirehtet and keep their settings apart
  (`nova-settings.json`). **Open Nova window** on the classic *Device* tab and **Classic
  window** in Nova close one and open the other, the normal way, so settings are saved.
* Nova's typefaces, DM Sans and Space Grotesk, ship in `nova/fonts/` under the SIL Open Font
  License.
* `nova/tests/` runs the real Nova window off screen: a test per page, and a tour that opens
  every page and inner tab at the default and the smallest size. CI also runs
  `nova/tests/audit.ps1` (no function defined twice, well-formed XAML, page-prefixed names).

### The classic window

* At the smallest window every page has room again. The log took a fixed share of the height
  and left the Files list about 40 px - not one row. Its height can now be dragged by the bar
  above its buttons, or the log folded away; the window remembers both. A short window also
  gives the device list two rows instead of four.
* Wi-Fi, Bluetooth and NFC are one tab, **Radios**. As three tabs of their own, fourteen in
  all, Users and Shell fell off the tab strip at the smallest window.
* The device list's columns share the width it has, so *Client* no longer hides behind a
  scroll bar.
* The battery and signal line stays on one line and ends in "..." when it does not fit; its
  tooltip holds the whole of it.
* The quick toggles show what the phone is doing: the On or Off button that matches it is
  tinted, read when the Device page opens, when another phone is picked and after each press.
  The ten settings are read in one trip to the phone instead of ten.
* A strip above the log names the adb call that is running, with a moving bar, once it takes
  longer than a moment. Before, a click that took seconds looked like one that did nothing.
* The label at the bottom right says **Sharing: off** instead of *Stopped*, which read as the
  state of the whole program. A bug report no longer empties it when it finishes.
* The device list follows the cable: a phone plugged in, pulled out or authorised is noticed
  within a few seconds, without pressing refresh.
* Keys that work anywhere in the window: `F5` reads the page on screen again, `Ctrl`+`1`…`9`
  open a tab, `Ctrl`+`L` empties the log.

## 1.0.0

The first release. One window on Windows that drives Android devices over plain `adb`, with
scrcpy and gnirehtet fetched from their official releases by `get-upstream.ps1`.

### What is in it

* **Device** - details, a live screenshot you can tap and swipe, quick toggles, call / SMS /
  USSD, one-click mirroring.
* **Tethering** - the PC's internet to the phone (gnirehtet), and the phone's to the PC over
  USB or a proxy.
* **Advanced** - every scrcpy option including virtual display, OTG, recording format, time
  limit and orientation; wireless pairing, mDNS discovery, bug report, private DNS, input
  methods, hotspot; a Root / recovery page marked against the real device.
* **Apps** - by name as well as package, launch, stop, uninstall, split APK bundles.
* **Contacts, SMS, Cam / Mic, Files, Running, Wi-Fi, Bluetooth, NFC, Users, Shell** - see the
  [user guide](docs/user-guide.md).
* Every list has its actions on the right mouse button; symbols replace words where a symbol
  is already known; every page fits the smallest window (1120 x 700).

### Fixed before release

Found by a review of the whole code, each checked against a phone:

* Text you type reaches the phone whole. adb and the phone's shell split arguments at spaces,
  and Windows PowerShell drops `"` inside them: an SMS body kept its first word, a Wi-Fi
  network or password with a space failed, a name with an apostrophe broke the command. Such
  text now travels as one quoted argument, encoded in base64
  ([what it runs](docs/what-it-runs.md)).
* *Turn Wi-Fi off while sharing* no longer turns Wi-Fi on at the end on a phone where it was
  off before; the same for `gnirehtet-share.ps1 -DisableWifi`.
* `get-upstream.ps1 -CacheFolder` deletes only the archives it used, not every `.zip` in that
  folder.
* Apps labelled user / system and enabled / disabled by whole package name, not by prefix.
* Search and *Recent files* hits: *Move to PC* deletes the phone copy once the PC copy is
  verified, and *Rename* and *Compress* work on them, from one folder or several.
* Filter boxes take `[ ]` and `*` literally.
* Wi-Fi networks sorted by signal strength as a number, and each saved network listed once:
  Android 15 prints a network once per security type it accepts, under the same id. Two saved
  networks whose names differ only in case ("KAIF 5G", "Kaif 5G") are two rows, not one.
* A new contact's details go to the row just created.
* When a phone refuses to install the sharing client over USB (`INSTALL_FAILED_USER_RESTRICTED`,
  seen on Xiaomi), the log says which setting allows it.
* Sharing can be started again right after it was stopped. Each start used the same log files,
  and a process the stopped relay had left behind still held them, so the new start failed with
  "being used by another process". Every start has its own files now.
* Logcat no longer silences the live shell; adb output is read as UTF-8 on any code page.

### Checks

CI parses every script, keeps them ASCII or BOM, fails on a variable read before it is set, on
a control that is never shown or a button with no handler, and on a hardcoded path. `tests\`
runs the real window against a phone: eleven tests - see [tests/README.md](tests/README.md).
