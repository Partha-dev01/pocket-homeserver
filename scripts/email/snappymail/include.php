<?php
// include.php — moves SnappyMail's data folder OUTSIDE the webroot (security +
// reproducibility). SnappyMail's bootstrap loads this top-level include.php
// (snappymail/v/<ver>/include.php, ~line 43) at startup. Deployed verbatim by
// scripts/steps/86-install-webmail.sh into the SnappyMail webroot inside the
// Debian userland. The path is fixed inside the userland (the large-volume data
// dir is bind-mounted here at supervise time), so it is NOT env-templated.
define('APP_DATA_FOLDER_PATH', '/opt/snappymail-data/');
