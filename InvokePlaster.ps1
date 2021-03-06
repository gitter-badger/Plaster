<#
.SYNOPSIS
    Invokes the specified plaster template which will scaffold out a file or set of files.
.DESCRIPTION
    Invokes the specified plaster template which will scaffold out a file or set of files.
.EXAMPLE
    C:\PS> Invoke-Plaster -TemplatePath NewModule.zip -Destination .\NewModule
    Explanation of what the example does
.NOTES
    General notes
#>
function Invoke-Plaster {
    [System.Diagnostics.CodeAnalysis.SuppressMessage('PSShouldProcess', '', Scope='Function', Target='GenerateModuleManifest')]
    [System.Diagnostics.CodeAnalysis.SuppressMessage('PSShouldProcess', '', Scope='Function', Target='ProcessTemplate')]
    [System.Diagnostics.CodeAnalysis.SuppressMessage('PSShouldProcess', '', Scope='Function', Target='ModifyFile')]
    [System.Diagnostics.CodeAnalysis.SuppressMessage('PSShouldProcess', '', Scope='Function', Target='ProcessFile')]
    [System.Diagnostics.CodeAnalysis.SuppressMessage('PSAvoidShouldContinueWithoutForce', '', Scope='Function', Target='ProcessFile')]
    [CmdletBinding(SupportsShouldProcess=$true)]
    param(
        # Specifies the path to either the Template directory or a ZIP file containing the template.
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $TemplatePath,

        # Specifies the path to directory in which the template will use as a root directory when generating files.
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $DestinationPath,

        # Specify Force to override user prompts for conflicting handling.  This will override the confirmation
        # prompt and allow the template to over write existing files.
        [Parameter()]
        [switch]
        $Force
    )

    # Process the template's plaster manifest file to convert parameters defined there into dynamic parameters.
    dynamicparam {
        $paramDictionary = New-Object System.Management.Automation.RuntimeDefinedParameterDictionary
        $manifest = $null
        $manifestPath = $null

        if ($null -eq $TemplatePath) {
            # Can't process dynamic parameters if we have no TemplatePath
            return
        }

        try {
            # If TemplatePath is a zipped template, extract the template to a temp dir and use that path
            $TemplatePath = ExtractTemplateAndReturnPath $TemplatePath

            $manifestPath = Join-Path $TemplatePath plasterManifest.xml
            if ($null -eq $manifestPath) {
                return
            }

            $manifestPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($manifestPath)
            if (!(Test-Path $manifestPath)) {
                return
            }

            $manifest = [xml](Get-Content $manifestPath -ErrorAction SilentlyContinue)

            # The user-defined parameters in the Plaster manifest are converted to dynamic parameters
            # which allows the user to provide all required parameters via the command line.
            # This enables non-interactive use cases.
            foreach ($node in $manifest.plasterManifest.parameters.ChildNodes) {
                if ($node -isnot [System.Xml.XmlElement] -and ($node.LocalName -eq 'parameter')) {
                    continue
                }

                $name = $node.name
                $type = $node.type
                $prompt = $node.prompt
                $default = $node.default

                if (!$name -or !$type) { continue }

                # Configure ParameterAttribute and add to attr collection
                $attributeCollection = New-Object System.Collections.ObjectModel.Collection[System.Attribute]
                $paramAttribute = New-Object System.Management.Automation.ParameterAttribute
                $paramAttribute.HelpMessage = $prompt
                $attributeCollection.Add($paramAttribute)

                switch ($type) {
                    'input' {
                        $param = New-Object System.Management.Automation.RuntimeDefinedParameter `
                                     -ArgumentList ($name, [string], $attributeCollection)
                        break
                    }

                    { 'choice','multichoice' -contains $_ } {
                        $choiceNodes = $node.SelectNodes('choice')
                        $setValues = New-Object string[] $choiceNodes.Count
                        $i = 0

                        foreach ($choiceNode in $choiceNodes){
                            $setValues[$i++] = ExpandString $choiceNode.value
                        }

                        $validateSetAttr = New-Object System.Management.Automation.ValidateSetAttribute $setValues
                        $attributeCollection.Add($validateSetAttr)
                        $type = if ($type -eq 'multichoice') { [string[]] } else { [string] }
                        $param = New-Object System.Management.Automation.RuntimeDefinedParameter `
                                     -ArgumentList ($name, $type, $attributeCollection)
                        break
                    }

                    default { throw ($LocalizedData.UnrecognizedParameterType_F2 -f $type,$name) }
                }

                $paramDictionary.Add($name, $param)
            }
        }
        catch [System.Exception] {
            Write-Verbose ($LocalizedData.ErrorProcessingDynamicParams_F1 -f $_)
        }

        $paramDictionary
    }

    begin {
        $boundParameters = $PSBoundParameters
        $confirmYesToAll = $false
        $confirmNoToAll = $false

        InitializePredefinedVariables $PSCmdlet.GetUnresolvedProviderPathFromPSPath($DestinationPath)

        # If user does not supply the TemplatePath parameter, the dynamicparam scriptblock bails early without
        # loading the Plaster manifest.  If that's the case, load the manifest now.
        if ($null -eq $manifestPath) {
            $TemplatePath = ExtractTemplateAndReturnPath $TemplatePath
            $manifestPath = Join-Path $TemplatePath plasterManifest.xml
            $manifestPath = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($manifestPath)
        }

        # Validate that the dynamicparam scriptblock was able to load the template manifest and it is valid.
        if ($null -eq $manifest) {
            if (Test-Path $manifestPath) {
                try {
                    # We have a valid path, try again and if successful - validate it.
                    $manifest = [xml](Get-Content $manifestPath)
                    Plaster\Test-PlasterManifest -InputObject $manifest -ErrorAction Stop
                }
                catch {
                    throw ($LocalizedData.ManifestNotValidXml_F1 -f $manifestPath)
                }
            }
            else {
                # TODO: Localize string
                throw "Missing manifest file: '$manifestPath'"
            }
        }
        else {
            Plaster\Test-PlasterManifest -InputObject $manifest -ErrorAction Stop
        }

        function PromptForInput($prompt, $default) {
            do {
                $value = Read-Host -Prompt $prompt
                if (!$value -and $default) {
                    $value = $default
                }
            } while (!$value)

            $value
        }

        function PromptForChoice([ValidateNotNull()]$ChoiceNodes, [string]$prompt, [int[]]$defaults, [switch]$IsMultiChoice) {
            $choices = New-Object 'System.Collections.ObjectModel.Collection[System.Management.Automation.Host.ChoiceDescription]'
            $values = New-Object object[] $ChoiceNodes.Count
            $i = 0

            foreach ($choiceNode in $ChoiceNodes) {
                $label = ExpandString $choiceNode.label
                $help = ExpandString $choiceNode.help
                $value = ExpandString $choiceNode.value

                if (!$label) {
                    throw ($LocalizedData.ManifestMissingAttribute_F2 -f $choiceNode.LocalName, 'help')
                }
                if (!$value) {
                    throw ($LocalizedData.ManifestMissingAttribute_F2 -f $choiceNode.LocalName, 'value')
                }

                $choice = New-Object System.Management.Automation.Host.ChoiceDescription -Arg $label,$help
                $choices.Add($choice)
                $values[$i++] = $value
            }

            if ($IsMultiChoice) {
                $selections = $Host.UI.PromptForChoice('', $prompt, $choices, $defaults)
                foreach ($selection in $selections) {
                    $values[$selection]
                }
            }
            else {
                if ($defaults.Count -gt 1) {
                    throw ($LocalizedData.ParameterTypeChoiceMultipleDefault_F1 -f $ChoiceNodes.ParentNode.name)
                }

                $selection = $Host.UI.PromptForChoice('', $prompt, $choices, $defaults[0])
                $values[$selection]
            }
        }

        function ProcessParameter([ValidateNotNull()]$ParamNode) {
            $name = $ParamNode.name
            $type = $ParamNode.type
            $prompt = ExpandString $ParamNode.prompt
            $default = ExpandString $ParamNode.default

            if (!$name) {
                throw ($LocalizedData.ManifestMissingAttribute_F2 -f $ParamNode.LocalName, 'name')
            }
            if (!$type) {
                throw ($LocalizedData.ManifestMissingAttribute_F2 -f $ParamNode.LocalName, 'type')
            }
            if (!$prompt) {
                throw ($LocalizedData.ManifestMissingAttribute_F2 -f $ParamNode.LocalName, 'prompt')
            }

            # Check if parameter was provided via a dynamic parameter
            if ($boundParameters.ContainsKey($name)) {
                $value =  $boundParameters[$name]
            }
            else {
                # Not a dynamic parameter so prompt user for the value
                $value = switch -regex ($type) {
                    'input'  {
                        if ($null -ne $default) {
                            $prompt += " ($default)"
                        }
                        PromptForInput $prompt $default
                    }
                    'choice|multichoice' {
                        $choices = $ParamNode.SelectNodes('choice')
                        $defaults = [int[]]($default -split ',')
                        PromptForChoice $choices $prompt $defaults -IsMultiChoice:($type -eq 'multichoice')
                    }
                    default  { throw ($LocalizedData.UnrecognizedAttribute_F1 -f $type, $ParamNode.LocalName) }
                }
            }

            # Make template defined parameters available as a PowerShell variable PLASTER_PARAM_<parameterName>
            Set-Variable -Name "PLASTER_PARAM_$name" -Value $value -Scope Script
        }

        function GenerateModuleManifest([ValidateNotNull()]$NewModuleManifestNode) {
            $moduleVersion = ExpandString $NewModuleManifestNode.moduleVersion
            $rootModule = ExpandString $NewModuleManifestNode.rootModule
            $author = ExpandString $NewModuleManifestNode.author
            $dstRelPath = ExpandString $NewModuleManifestNode.destination
            $dstPath = $PSCmdlet.GetUnresolvedProviderPathFromPSPath((Join-Path $DestinationPath $dstRelPath))

            $condition  = $NewModuleManifestNode.condition
            if ($condition) {
                if (!(EvaluateCondition $condition)) {
                    Write-Verbose "Skipping module manifest generation for '$dstPath', condition evaluated to false."
                    return
                }
            }

            # TODO: This generates a file and as such should participate in file
            # conflict resolution. I think we should gen the file here and then
            # use the normal ProcessFile (or function used by ProcessFile) to handle file conflicts.
            if ($PSCmdlet.ShouldProcess($dstPath, $LocalizedData.ShouldProcessGenerateModuleManifest)) {
                $manifestDir = Split-Path $dstPath -Parent
                if (!(Test-Path $manifestDir)) {
                    # TODO: Create a function for this that tests that the directory is under
                    #       the destination directory.
                    Write-Verbose "Creating destination dir for module manifest: $manifestDir"
                    New-Item $manifestDir -ItemType Directory > $null
                }

                # TODO: Temporary - remove this when this function makes use of ProcessFile
                WriteOperationStatus 'Create' (ConvertToDestinationRelativePath $dstPath)

                New-ModuleManifest -Path $dstPath -ModuleVersion $moduleVersion -RootModule $rootModule -Author $author
                $content = Get-Content -LiteralPath $dstPath -Raw
                Set-Content -LiteralPath $dstPath -Value $content -Encoding UTF8
            }
        }

        function AreFilesIdentical($Path1, $Path2) {
            $file1 = Get-Item -LiteralPath $Path1
            $file2 = Get-Item -LiteralPath $Path2

            if ($file1.Length -ne $file2.Length) {
                return $false
            }

            $hash1 = (Get-FileHash -LiteralPath $path1 -Algorithm SHA1).Hash
            $hash2 = (Get-FileHash -LiteralPath $path2 -Algorithm SHA1).Hash

            $hash1 -eq $hash2
        }

        function ProcessTemplate([string]$Path, $encoding) {
            if ($PSCmdlet.ShouldProcess($Path, $LocalizedData.ShouldProcessTemplateFile)) {
                $content = Get-Content $Path -Raw
                $pattern = '(<%=)(.*?)(%>)'
                $newContent = [regex]::Replace($content, $pattern, {
                    param($match)
                    $expr = $match.groups[2].value
                    Write-Verbose "Replacing template expr $expr in '$Path'"
                    ExpandString $expr
                },  @('IgnoreCase', 'SingleLine', 'MultiLine'))

                Set-Content -Path $Path -Value $newContent -Encoding $encoding
            }
        }

        function ProcessFile([ValidateNotNull()]$FileNode) {
            $srcRelPath = ExpandString $FileNode.source
            $dstRelPath = ExpandString $FileNode.destination
            $condition  = $FileNode.condition
            if ($condition) {
                if (!(EvaluateCondition $condition)) {
                    Write-Verbose "Skipping file '$dstRelPath', condition evaluated to false."
                    return
                }
            }

            $encoding = ExpandString $FileNode.encoding
            $isTemplate = $FileNode.template -eq 'true'

            if (!$encoding) {
                $encoding = $DefaultEncoding
            }

            $srcPath = $PSCmdlet.GetUnresolvedProviderPathFromPSPath((Join-Path $TemplatePath $srcRelPath))
            $dstPath = $PSCmdlet.GetUnresolvedProviderPathFromPSPath((Join-Path $DestinationPath $dstRelPath))

            # If the file's parent dir doesn't exist, create it.
            $parentDir = Split-Path $dstPath -Parent
            if (!(Test-Path $parentDir)) {
                if ($PSCmdlet.ShouldProcess($parentDir, $LocalizedData.ShouldProcessCreateDir)) {
                    New-Item -Path $parentDir -ItemType Directory > $null
                }
            }

            $operation = $LocalizedData.OpCreate
            if (Test-Path $dstPath) {
                if (AreFilesIdentical $srcPath $dstPath) {
                    $operation = $LocalizedData.OpIdentical
                }
                else {
                    $operation = $LocalizedData.OpConflict
                }
            }

            # Copy the file to the destination
            if ($PSCmdlet.ShouldProcess($dstPath, $operation)) {
                WriteOperationStatus $operation (ConvertToDestinationRelativePath $dstPath)
                if ($operation -ne $LocalizedData.OpConflict) {
                    Copy-Item -LiteralPath $srcPath -Destination $dstPath
                }
                elseif ($Force -or $PSCmdlet.ShouldContinue(($LocalizedData.OverwriteFile_F1 -f $dstPath),
                                                             $LocalizedData.FileConflict,
                                                             [ref]$confirmYesToAll, [ref]$confirmNoToAll)) {
                    Copy-Item -LiteralPath $srcPath -Destination $dstPath
                }
            }

            # If file is a template, process the template
            if ($isTemplate) {
                WriteOperationStatus $LocalizedData.OpExpand (ConvertToDestinationRelativePath $dstPath)
                ProcessTemplate $dstPath $encoding
            }
        }

        function ModifyFile([ValidateNotNull()]$ModifyNode) {
            $path = ExpandString $ModifyNode.path
            $filePath = $PSCmdlet.GetUnresolvedProviderPathFromPSPath((Join-Path $DestinationPath $path))

            $PLASTER_FileContent = ''
            if (Test-Path $filePath) {
                $PLASTER_FileContent = Get-Content -LiteralPath $filePath -Raw
            }

            $condition  = $ModifyNode.condition
            if ($condition) {
                if (!(EvaluateCondition $condition)) {
                    Write-Verbose "Skipping file modify on '$path', condition evaluated to false."
                    return
                }
            }

            $encoding = ExpandString $ModifyNode.encoding
            if (!$encoding) {
                $encoding = $DefaultEncoding
            }

            if ($PSCmdlet.ShouldProcess($filePath, $LocalizedData.ShouldProcessModifyContent)) {
                WriteOperationStatus $LocalizedData.OpModify (ConvertToDestinationRelativePath $filePath)

                $modified = $false

                foreach ($node in $ModifyNode.ChildNodes) {
                    if ($node -isnot [System.Xml.XmlElement]) { continue }

                    switch ($node.LocalName) {
                        'replacement' {
                            # TODO: Support expand on pattern / replacement string needs some thinking - might need to escape double quotes.
                            $pattern = $node.pattern # ExpandString $node.pattern
                            $replacement = $node.InnerText # ExpandString $node.InnerText

                            $PLASTER_FileContent = $PLASTER_FileContent -replace $pattern,$replacement

                            $modified = $true
                        }
                        default { throw ($LocalizedData.UnrecognizedContentElement_F1 -f $node.LocalName) }
                    }
                }

                if ($modified) {
                    Set-Content -LiteralPath $filePath -Value $PLASTER_FileContent -Encoding $encoding
                }
            }
        }
    }

    end {
        # Process parameters
        foreach ($node in $manifest.plasterManifest.parameters.ChildNodes) {
            if ($node -isnot [System.Xml.XmlElement]) { continue }
            switch ($node.LocalName) {
                'parameter'  { ProcessParameter $node }
                default      { throw ($LocalizedData.UnrecognizedParametersElement_F1 -f $node.LocalName) }
            }
        }

        $parameters = Get-Variable -Name PLASTER_* | Out-String
        Write-Verbose "Parameter values are:`n$($parameters -split "`n")"

        # Process content
        foreach ($node in $manifest.plasterManifest.content.ChildNodes) {
            if ($node -isnot [System.Xml.XmlElement]) { continue }

            switch ($node.LocalName) {
                'file'              { ProcessFile $node; break }
                'modify'            { ModifyFile $node; break }
                'newModuleManifest' { GenerateModuleManifest $node; break }
                default             { throw ($LocalizedData.UnrecognizedContentElement_F1 -f $node.LocalName) }
            }
        }
    }
}

function InitializePredefinedVariables([string]$destPath) {
    $destName = Split-Path -Path $destPath -Leaf
    Set-Variable -Name PLASTER_DestinationPath -Value $destPath.TrimEnd('\','/') -Scope Script
    Set-Variable -Name PLASTER_DestinationName -Value $destName -Scope Script

    Set-Variable -Name PLASTER_Guid1 -Value ([Guid]::NewGuid()) -Scope Script
    Set-Variable -Name PLASTER_Guid2 -Value ([Guid]::NewGuid()) -Scope Script
    Set-Variable -Name PLASTER_Guid3 -Value ([Guid]::NewGuid()) -Scope Script
    Set-Variable -Name PLASTER_Guid4 -Value ([Guid]::NewGuid()) -Scope Script
    Set-Variable -Name PLASTER_Guid5 -Value ([Guid]::NewGuid()) -Scope Script

    $now = [DateTime]::Now
    Set-Variable -Name PLASTER_Date -Value ($now.ToShortDateString()) -Scope Script
    Set-Variable -Name PLASTER_Time -Value ($now.ToShortTimeString()) -Scope Script
    Set-Variable -Name PLASTER_Year -Value ($now.Year) -Scope Script
}

function ExpandString($str) {
    if ($null -eq $str) {
        return ''
    }

    # There are at least two ways to go to provide "safe" string evaluation with *only* variable
    # expansion and not arbitrary script execution via subexpressions.  We could a regex to pull
    # out a variable name e.g. '\$\{(.*?)\}', then use
    # [System.Management.Automation.Language.CodeGeneration]::EscapeVariableName followed by
    # $ExecutionContext.InvokeCommand.ExpandString().  The other way to go is to pick a specific part
    # of the AST and vet it before using $ExecutionContext.InvokeCommand.ExpandString().

    $sb = [scriptblock]::Create("`"$str`"")

    $endBlockAst = $sb.Ast.EndBlock.Statements[0].PipelineElements[0]
    if ($endBlockAst -isnot [System.Management.Automation.Language.CommandExpressionAst]) {
        throw ($LocalizedData.SubsitutionExpressionInvalid_F1 -f $endBlockAst.Extent.Text)
    }

    if ($endBlockAst.Expression -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
        $evalStr = $endBlockAst.Expression.Value
    }
    elseif ($endBlockAst.Expression -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) {
        foreach ($nestedExpr in $endBlockAst.Expression.NestedExpressions) {
            if ($nestedExpr -isnot [System.Management.Automation.Language.VariableExpressionAst]) {
                throw ($LocalizedData.SubsitutionExpressionInvalid_F1 -f $endBlockAst.Extent.Text)
            }
        }

        $evalStr = $endBlockAst.Expression.Value
    }
    else {
        throw ($LocalizedData.SubsitutionExpressionInvalid_F1 -f $endBlockAst.Extent.Text)
    }

    $ExecutionContext.InvokeCommand.ExpandString($evalStr)
}

function EvaluateCondition([string]$expr) {
    # TODO: Yeah, this is *not* a safe eval function - yet.

    $sb = [scriptblock]::Create($expr)
    $res = $sb.Invoke()
    [bool]$res
}

function ConvertToDestinationRelativePath($Path) {
    $fullDestPath = $DestinationPath
    if (![System.IO.Path]::IsPathRooted($fullDestPath)) {
        $fullDestPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($DestinationPath)
    }

    $fullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    if (!$fullPath.StartsWith($fullDestPath, 'OrdinalIgnoreCase')) {
        throw "$Path must contain $fullDestPath"
    }

    $fullPath.Substring($fullDestPath.Length).TrimStart('\','/')
}

function ColorForOperation($operation) {
    switch ($operation) {
        $LocalizedData.OpConflict  { 'Red' }
        $LocalizedData.OpCreate    { 'Green' }
        $LocalizedData.OpExpand    { 'Green' }
        $LocalizedData.OpIdentical { 'Cyan' }
        $LocalizedData.OpModify    { 'Green' }
        default { $Host.UI.RawUI.ForegroundColor }
    }
}

function WriteOperationStatus($operation, $message) {
    $maxLen = ($LocalizedData.OpCreate, $LocalizedData.OpIdentical,
               $LocalizedData.OpConflict, $LocalizedData.OpExpand,
               $LocalizedData.OpModify | Measure-Object -Property Length -Maximum).Maximum

    Write-Host ("{0,$maxLen} " -f $operation) -ForegroundColor (ColorForOperation $operation) -NoNewline
    Write-Host $message
}
