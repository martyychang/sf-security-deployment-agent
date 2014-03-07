## scripts

The files in this folder are required for the current version of sf-security-deployment-agent to run.

### convenience.rb

A simple, custom module that is required for a few of the scripts to execute

### knowns.csv 

A two-column CSV file enumerating the API names of known components that should be included in the prepared package. This file is important because the profile and permission set metadata files intentionally leave out some implicit permissions that we have to manually track.

**Tip**: There are categories that are known to be incomplete: "StandardProfile" and "settableStandardProfileUserPermissions".

* "StandardProfile" is designed to give the name (__.profile) of standard Salesforce profiles being deployed. This is needed because you cannot set most app and system permissions for standard profiles.
* "settableStandardProfileUserPermissions" is designed to provide exceptions to the above "rule", in the rare case where an app or system permission actually can be toggled for standard profiles. The value that should go into the **Name** column should match what's already defined for "userPermissions".

For example: Only system and app permissions that are enabled (have a marked checkbox in the UI) are included in the .profile file. 

### prepare_permissionsets_for_deployment.rb

Ruby script used to prepare a .zip package containing **permission set** settings that can be deployed to a destination org, using metadata retrieved from both the source org and the destination org.

### prepare_profile_for_deployment.rb

Ruby script used to prepare a .zip package containing **profile** settings that can be deployed to a destination org, using metadata retrieved from both the source org and the destination org.

### retrieve_profiles_and_permissionsets.rb

Ruby script used to retrieve all the profile and permission set information that is retrievable from an org, using the Metadata API.