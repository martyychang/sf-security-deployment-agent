## scripts

The files in this folder are required for the current version of sf-security-deployment-agent to run.

### convenience.rb

A simple, custom module that is required for a few of the scripts to execute

### knowns.csv 

A two-column CSV file enumerating the API names of known components that should be included in the prepared package. This file is important because the profile and permission set metadata files intentionally leave out some implicit permissions that we have to manually track.

For example: Only system and app permissions that are enabled (have a marked checkbox in the UI) are included in the .profile file. 

### prepare_permissionsets_for_deployment.rb

Ruby script used to prepare a .zip package containing **permission set** settings that can be deployed to a destination org, using metadata retrieved from both the source org and the destination org.

### prepare_profile_for_deployment.rb

Ruby script used to prepare a .zip package containing **profile** settings that can be deployed to a destination org, using metadata retrieved from both the source org and the destination org.

### retrieve_profiles_and_permissionsets.rb

Ruby script used to retrieve all the profile and permission set information that is retrievable from an org, using the Metadata API.