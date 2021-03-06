# Copyright 2011-2013 Amazon.com, Inc. or its affiliates. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License"). You
# may not use this file except in compliance with the License. A copy of
# the License is located at
#
#     http://aws.amazon.com/apache2.0/
#
# or in the "license" file accompanying this file. This file is
# distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF
# ANY KIND, either express or implied. See the License for the specific
# language governing permissions and limitations under the License.

<# 
.SYNOPSIS
    NAME: RunHiveDemoJob.ps1
    This script shows how to run the hive job from powershell associated with the article "Contextual Advertising using Apache Hive and Amazon EMR" found out
    http://aws.amazon.com/articles/2855?_encoding=UTF8&jiveRedirect=1, in the section "Running in Script Mode" 
        
.DESCRIPTION
    This script creates a hive script EMR job. It assumes that the AWS tools for Windows Powershell library have
    been installed to your system in the default location.  For more information see http://aws.amazon.com/powershell/.  Helper functions show how to create a java
    step, and StepConfig (which contains a step to add to a job).

.PARAMETER LogFileBucket
    This parameter specifies an existing S3 bucket to write the log files for the job to.
    DEFAULT: N/A
    Example: Create-InteractiveHiveJob.ps1 -LogFileBucket MyBucketName

.PARAMETER ResultOutputPath
    This parameter specifies an existing S3 bucket and path to write the log files for the job to.  For example mybucket/ResultOutputPath.  The bucket must exist, but the folder should not.
    DEFAULT: N/A
    Example: Create-InteractiveHiveJob.ps1 -HiveOutputPath MyBucketName/jobout
                                
.PARAMETER AvailabilityZone
    This parameter specifies the availability zone to launch the instance to.
    DEFAULT: us-east-1b
    Example: Create-InteractiveHiveJob.ps1 -AvailabilityZone us-east-1a
    
.EXAMPLE
     Create-InteractiveHiveJob.ps1 

.NOTES
               NAME: RunHiveDemoJob.ps1
               AUTHOR: Chris Keyser   
               AUTHOR EMAIL: ckeyser@amazon.com
               CREATION DATE: 1/18/2013
               LAST MODIFIED DATE:  1/18/2013
               LAST MODIFIED BY: Chris Keyser
               RELEASE VERSION: 0.0.1
#>
param( 
    [string] $LogFileBucket,
    [string] $ResultOutputPath,
    [string] $AvailabilityZone
    )

Import-Module AWSPowerShell

if($LogFileBucket.length -eq 0)
{
    $LogFileBucket = Read-Host -prompt "Enter Log File Bucket"
}

if($ResultOutputPath.length -eq 0)
{
    $ResultOutputPath = Read-Host -prompt "Enter output path (ex: mybucket/exampleout). The folder should not exist."
    $ResultOutputPath = $ResultOutputPath.Trim()
}

if($AvailabilityZone.length -eq 0)
{
    $AvailabilityZone="us-east-1b"
}

$logUri = "s3n://" + $LogFileBucket + "/"
$outUri = "OUTPUT=s3://" +  $ResultOutputPath

#this is the jar file for running scripts provided by S3...
$scriptjar = "s3://us-east-1.elasticmapreduce/libs/script-runner/script-runner.jar"

#
# This helper function creates a java step for executing a map step based upon a jar
#
Function CreateJavaStep
{
    param([string]$jar, 
        [string[]] $jarargs 
    )
    
    $jarstep=New-Object Amazon.ElasticMapReduce.Model.HadoopJarStepConfig
    $jarstep.Jar=$jar
    
    # add arguments and values as individual items
    foreach($jararg in $jarargs)
    {
        $jarstep.Args.Add($jararg);
    }
    
    return $jarstep
}

#
# This helper function step creates a step config, which specifies a step being submitted to the hadoop cluster.
#
Function CreateStepConfig
{
    param([string]$name, 
            [Amazon.ElasticMapReduce.Model.HadoopJarStepConfig] $stepToAdd, 
            [string]$actionOnFailure="CANCEL_AND_WAIT"
    )
     
    $stepconfig=New-Object  Amazon.ElasticMapReduce.Model.StepConfig
    $stepconfig.HadoopJarStep=$stepToAdd
    $stepconfig.Name=$name
    $stepconfig.ActionOnFailure=$actionOnFailure

    return $stepconfig
}

#
# This helper function adds a java step to a job.
#
Function AddJavaStep
{
    param([string]$name, 
        [string]$jar, 
        [string]$jobid, 
        [string[]] $jarargs, 
        [string]$actionOnFailure="CANCEL_AND_WAIT"
    )

    $step = CreateJavaStep $jar $jarargs
    $stepconfig = CreateStepConfig $name $step $actionOnFailure
    Add-EMRJobFlowStep -JobFlowId $jobid -Steps $stepconfig
}

$stepFactory = New-Object  Amazon.ElasticMapReduce.Model.StepFactory
$hiveVersion = [Amazon.ElasticMapReduce.Model.StepFactory+HiveVersion]::Hive_Latest
$hiveSetupStep = $stepFactory.NewInstallHiveStep($hiveVersion)
$createHiveStepConfig = CreateStepConfig "Test Interactive Hive" $hiveSetupStep

# adding the hive script discretely instead of using the factory to create the step since the factory method does
# doesn't support specifying the hive version for running the hive script step.  This causes the step to fail as the
# hive versions mismatch.

$runhivescriptargs = @("s3://us-east-1.elasticmapreduce/libs/hive/hive-script", `
                "--base-path", "s3://us-east-1.elasticmapreduce/libs/hive", `
                "--hive-versions","latest", `
                "--run-hive-script", `
                "--args", `
                "-f", "s3://elasticmapreduce/samples/hive-ads/libs/join-clicks-to-impressions.q", `
                "-d", "SAMPLE=s3://elasticmapreduce/samples/hive-ads",`
                "-d", "DAY=2009-04-13", `
                "-d", "HOUR=08", `
                "-d", "NEXT_DAY=2009-04-13", `
                "-d", "NEXT_HOUR=09",`
                "-d", "INPUT=s3://elasticmapreduce/samples/hive-ads/tables", `
                "-d", $outUri, `
                "-d", "LIB=s3://elasticmapreduce/samples/hive-ads/libs")
                      
$adsProcessingStep = CreateJavaStep $scriptjar $runhivescriptargs
$runAdsScriptStepConfig = CreateStepConfig "Processing Ads" $adsProcessingStep

$jobsteps = @($createHiveStepConfig, $runAdsScriptStepConfig)

$jobid = Start-EMRJobFlow -Name "Join Clicks PS" `
                          -Instances_MasterInstanceType "m1.large" `
                          -Instances_SlaveInstanceType "m1.large" `
                          -Instances_KeepJobFlowAliveWhenNoSteps $false `
                          -Instances_Placement_AvailabilityZone $AvailabilityZone `
                          -Instances_InstanceCount 1 `
                          -Steps $jobsteps `
                          -LogUri $loguri `
                          -VisibleToAllUsers $true `
                          -AmiVersion "latest" `


#
# these loops are for demo purposes, and display the status of the job as it is ran.
# they are not necessary for the job to complete.
#

do {
    Start-Sleep 10
    $waitingiswaiting = Get-EMRJobFlow -JobFlowStates ("STARTING") -JobFlowId $jobid
    $waitcnt = $waitcnt + 10
    Write-Host "Starting..." $waitcnt
}while($waitingiswaiting.Count -eq 1)
                          
do {
    Start-Sleep 10
    $waitingiswaiting = Get-EMRJobFlow -JobFlowStates ("RUNNING") -JobFlowId $jobid
    $waitcnt = $waitcnt + 10
    Write-Host "Running..." $waitcnt
}while($waitingiswaiting.Count -eq 1)

do {
    Start-Sleep 10
    $waitingiswaiting = Get-EMRJobFlow -JobFlowStates ("SHUTTING_DOWN") -JobFlowId $jobid
    $waitcnt = $waitcnt + 10
    Write-Host "Shutting Down..." $waitcnt
}while($waitingiswaiting.Count -eq 1)

Write-Host "Completed"
