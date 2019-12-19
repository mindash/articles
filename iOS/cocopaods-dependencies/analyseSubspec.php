<?php
#$output = shell_exec("find '/Users/jeromemorissard/.cocoapods/repos/master/Specs/' -type f -name '*.json' > jsons.txt");
$handle = fopen("jsons.txt", "r");

#$handle = fopen("json.txt", "r");
$pod2version = Array();
$pod2subspecs = Array();
$pod2homepage = Array();

if ($handle) {
	while (($line = fgets($handle)) !== false) {
		$line = trim(preg_replace('/\s\s+/', ' ', $line));
		$string = file_get_contents($line);
		$json_a = json_decode($string, true);
		$name = $json_a["name"];
		$version = $json_a["version"];
		$subpsecs = $json_a["subspecs"];
		$homepage = $json_a["homepage"];
		
		$nb = sizeOf($subpsecs);
		if ($pod2version[$name]){
			$v1 = $pod2version[$name];
			$v2 = $version;
			if (version_compare($v1, $v2) < 0){
				$pod2version[$name] = $version;
				$pod2subspecs[$name] = $subpsecs;
				$pod2homepage[$name] = $homepage;
			}
			
		} else {
			$pod2version[$name] = $version;
			$pod2subspecs[$name] = $subpsecs;
			$pod2homepage[$name] = $homepage;
		}
	}
	
	fclose($handle);
} 

$keys = array_keys($pod2subspecs);
#$keys = ["SDWebImage"];
$l = sizeOf($keys);

function numberOfDependencies_level1($pod2subspecs, $podName){
	$subpsecs = $pod2subspecs[$podName];
	return sizeOf($subpsecs);
}

function numberOfInternalDependencies($pod2subspecs, $podName){
	$clean_pod_name = str_replace("/","",$podName);
	#print("\t$clean_pod_name\n");
	$subpsecs = $pod2subspecs[$clean_pod_name];
	$nb_level = sizeOf($subpsecs);
	$nb_dependencies = 0;
	
	for ($j = 0; $j < $nb_level; $j++){
		$subspec = $subpsecs[$j];
		$subname = $subspec["name"];
		$dependencies = $subspec["dependencies"];
		$nb_level_2 = sizeOf($dependencies);
		$nb_dependencies = 1 + $nb_dependencies + $nb_level_2;
		#$nb_dependencies = $nb_dependencies + numberOfInternalDependencies($pod2subspecs, $subname);
		
		for ($k = 0; $k < $nb_level_2; $k++){
			$dep_subspec = $dependencies[$k];
			$dep_name = $dep_subspec["name"];
			$nb_dependencies = $nb_dependencies + numberOfInternalDependencies($pod2subspecs, $dep_name);
		}
	}
	
	return $nb_dependencies;
}

for ($i = 0; $i < $l; $i++){
	$name = $keys[$i];
	$jsonPath = "pod-jsons/$name.json";
	$nb_level1 = numberOfDependencies_level1($pod2subspecs, $name);
	$nb_levelX = numberOfInternalDependencies($pod2subspecs, $name);
	
	// GET stars ! 
	$homepage = $pod2homepage[$name];
	// https://github.com/MaxHasADHD/TraktKit
	$jsonPage = str_replace("https://github.com/","https://api.github.com/repos/",$homepage);
	$cmd = "wget -O $jsonPath $homepage";
	shell_exec($cmd);
	$string = file_get_contents($jsonPath);
	$json = json_decode ($string);
	$stars = $json["stargazers_count"];
	print "$name\t$nb_level1\t$nb_levelX\t$stars\n";
	shell_exec($cmd);
}


/*
<?php
$output = shell_exec("find '/Users/jeromemorissard/.cocoapods/repos/master/Specs/' -type f -name '*.json' > jsons.txt");
$handle = fopen("jsons.txt", "r");
$pod2nb = Array();
if ($handle) {
	while (($line = fgets($handle)) !== false) {
		$line = trim(preg_replace('/\s\s+/', ' ', $line));
		$string = file_get_contents($line);
		$json_a = json_decode($string, true);
		$name = $json_a["name"];
		$subpsecs = $json_a["subspecs"];
		$nb = sizeOf($subpsecs);
		#print "$name\t$nb\n";
		$pod2nb[$name] = $nb;
	}
	fclose($handle);
} 

$keys = array_keys($pod2nb);
$l = sizeOf($keys);

for ($i = 0; $i < $l; $i++){
	$name = $keys[$i];
	$nb = $pod2nb[$name];
	print "$name\t$nb\n";
}

?>
*/
?>

