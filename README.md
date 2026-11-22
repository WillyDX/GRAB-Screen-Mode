<h1>GRAB-Screen-Mode:</h1>
A program that lets you play, not just grab, but any VR game on steam in flatscreen as if you have a vr headset connected trough steamvr!
This "Virtual" headset is always on and can be controlled by other apps
<p></p>
(To be fair I have just tested it with GRAB but it acts like you have a steamvr headset and even stuff like roblox studio reacts to it so...)

<h2>Usage:</h2>
Before anything run setup.bat, It will make sure everything is in place, then, just run run_flatscreen.bat. If your mouse locks to the center of the screen and steamvr opens you're ready to load up your game! Just press f8 to unlock your mouse and launch the game from within steam

<p><b>WAIRNING: You may need to set steamver as the default openxr runtime, you can do this in steamvr's settings</b></p>

<h2>Files:</h2>

·cleanup_novr.ps1: It disables the virtual headset as it's always enabled, use it if you get trouble with apps thinking you're in vr

·flatscreen_vr.py: This is a rudimentary controller, it moves the headset in the real world and lets you look around

·mouselook.py: an old version of flatscreen_vr, it's broken, deprecated, and shouldn't be used, it's still added for entertainment purposes I guess

·requirements.txt: The python APIs needed to run the flatscreen_vr script

·run_flatscreen.bat: It runs steamvr and flatscreen_vr.py. It's basically the "launcher"after using it you should press f8 (To unluck your mouse) then navigate to steam and press play on your preferred vr game

·run_novr_setup.bat: This one just launches steamvr on its own, it's like the most minimal version of the proyect

·setup.bat: A quality-of-life script that installs everything needed to run all this

·setup_novr.ps1: The actual powershell file used to run steamvr and configure stuff
