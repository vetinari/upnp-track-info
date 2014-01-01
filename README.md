upnp-track-info
===============

show what's played on the local upnp renderers

Required modules
----------------

For a debian system, do a

  sudo apt-get install libnet-upnp-perl libhttp-daemon-perl \
    libhttp-message-perl libxml-simple-perl libjson-perl libtext-iconv-perl

Config
------
* change `$local_addr` to match your local address
* you probably want to set `$log_level` to `'INFO'`
