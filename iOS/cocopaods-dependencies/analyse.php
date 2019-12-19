<?php
$output = shell_exec("find '/Users/jeromemorissard/.cocoapods/repos/master/Specs/' -type f -name '*.json' > jsons.txt");
$handle = fopen("jsons.txt", "r");
$podnames = Array();
if ($handle) {
	while (($line = fgets($handle)) !== false) {
		$line = trim(preg_replace('/\s\s+/', ' ', $line));
		$string = file_get_contents($line);
		$json_a = json_decode($string, true);
		$name = $json_a["name"];
		$podnames[$name] = $name;
	}
	fclose($handle);
} 

$keys = array_keys($podnames);
$l = sizeOf($keys);
print("$l distinct pods");
?>