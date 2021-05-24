Param(
    [string] $ResourceGroupLocation = 'West Europe',
    [string] $ResourceGroupName = 'MyRG',
    [string] $StorageAccountName,
    [string] $StorageContainerName = $ResourceGroupName.ToLowerInvariant() + '-stageartifacts',
    [string] $TemplateFile = "main.json",
    [string] $TemplateParametersFile = "parameters.json",
    [string] $ArtifactStagingDirectory = '.'
)

# Create the resource group only when it doesn't already exist
if ($null -eq (Get-AzResourceGroup -Name $ResourceGroupName -Location $ResourceGroupLocation -Verbose -ErrorAction SilentlyContinue)) {
    New-AzResourceGroup -Name $ResourceGroupName -Location $ResourceGroupLocation -Verbose -Force -ErrorAction Stop
}

# Create a storage account name if none was provided
if ($StorageAccountName -eq '') {
    $StorageAccountName = $ResourceGroupName.ToLowerInvariant() + ((Get-AzContext).Subscription.SubscriptionId).Replace('-', '').substring(0, 10)
}
$StorageAccount = (Get-AzStorageAccount | Where-Object { $_.StorageAccountName -eq $StorageAccountName })

# Create the storage account if it doesn't already exist
if ($null -eq $StorageAccount) {
    $StorageAccount = New-AzStorageAccount -StorageAccountName $StorageAccountName -Type 'Standard_LRS' -ResourceGroupName $ResourceGroupName -Location "$ResourceGroupLocation"
}

#Optional Parameters Hash Table for ARM Template
$OptionalParameters = New-Object -TypeName Hashtable

# Convert relative paths to absolute paths
$TemplateFile = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, $TemplateFile))
$TemplateParametersFile = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, $TemplateParametersFile))
$ArtifactStagingDirectory = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, $ArtifactStagingDirectory))
$DSCSourceFolder = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, $DSCSourceFolder))

# _artifactsLocation,_artifactsLocationSasToken,sqlAdministratorLoginPassword,KeyvaultId Parameters Value
$ArtifactsLocationName = '_artifactsLocation'
$ArtifactsLocationSasTokenName = '_artifactsLocationSasToken'

# Generate the value for artifacts location if it is not provided in the parameter file
if ($null -eq $OptionalParameters[$ArtifactsLocationName]) {
    $OptionalParameters[$ArtifactsLocationName] = $StorageAccount.Context.BlobEndPoint + $StorageContainerName
}
# Copy files from the local storage staging location to the storage account container
New-AzStorageContainer -Name $StorageContainerName -Context $StorageAccount.Context -ErrorAction SilentlyContinue *>&1
$ArtifactFilePaths = Get-ChildItem $ArtifactStagingDirectory -Recurse -File | ForEach-Object -Process { $_.FullName }
foreach ($SourcePath in $ArtifactFilePaths) {
    Set-AzStorageBlobContent -File $SourcePath -Blob $SourcePath.Substring($ArtifactStagingDirectory.length + 1) `
        -Container $StorageContainerName -Context $StorageAccount.Context -Force
}

# Generate a 4 hour SAS token for the artifacts location if one was not provided in the parameters file
if ($null -eq $OptionalParameters[$ArtifactsLocationSasTokenName]) {
    $OptionalParameters[$ArtifactsLocationSasTokenName] = ConvertTo-SecureString -AsPlainText -Force `
    (New-AzStorageContainerSASToken -Container $StorageContainerName -Context $StorageAccount.Context -Permission r -ExpiryTime (Get-Date).AddHours(4))
}

#Arm Template Deployment
New-AzResourceGroupDeployment -Name ((Get-ChildItem $TemplateFile).BaseName + '-' + ((Get-Date).ToUniversalTime()).ToString('MMdd-HHmm')) `
    -ResourceGroupName $ResourceGroupName `
    -TemplateFile $TemplateFile `
    -TemplateParameterFile $TemplateParametersFile `
    @OptionalParameters `
    -Force -Verbose `
    -ErrorVariable ErrorMessages
