-- CueToRecipe v1.3
-- Converts Cue values into Standard Recipes.
--
-- 1. Detects the exact matching Group.
-- 2. Detects Presets referenced in the Cue XML.
-- 3. Creates the Standard Recipes.
-- 4. Removes the corresponding hard-coded values.
-- 5. Runs a final Cook /Merge.
-- 6. Deletes temporary XML files.
--
-- WARNING:
-- Test on a copy of the sequence first.

local function readSelection()
    local selection = {}
    local count = 0
    local index = SelectionFirst()

    while index ~= nil do
        selection[index] = true
        count = count + 1
        index = SelectionNext(index)
    end

    return selection, count
end

local function selectionsAreIdentical(a, b)
    for index in pairs(a) do
        if b[index] ~= true then
            return false
        end
    end

    for index in pairs(b) do
        if a[index] ~= true then
            return false
        end
    end

    return true
end

local function getName(object)
    local name = object:Get("NAME")

    if name == nil or name == "" then
        return nil
    end

    return tostring(name)
end

local function getDisplayName(object)
    return getName(object) or object:ToAddr()
end

local function selectAndRead(command)
    Cmd("ClearSelection")
    Cmd(command)

    return readSelection()
end

local function decodeXml(text)
    return text
        :gsub("&apos;", "'")
        :gsub("&quot;", '"')
        :gsub("&lt;", "<")
        :gsub("&gt;", ">")
        :gsub("&amp;", "&")
end

local function quoteCommandText(text)
    text = tostring(text)
    text = text:gsub("\\", "\\\\")
    text = text:gsub('"', '\\"')

    return '"' .. text .. '"'
end

local function findPresetPool(poolName)
    local presetPools = DataPool().PresetPools

    if presetPools == nil then
        return nil
    end

    for _, pool in ipairs(presetPools:Children()) do
        if getName(pool) == poolName then
            return pool
        end
    end

    return nil
end

local function findPreset(
    poolName,
    presetName,
    presetNumber
)
    local pool = findPresetPool(poolName)

    if pool == nil then
        return nil
    end

    -- Preset without a label:
    -- Example: gGobo.4
    if presetNumber ~= nil then
        local number = tonumber(presetNumber)

        if number ~= nil then
            return pool[number]
        end
    end

    -- Named Preset:
    -- Example: gColor.'8R Blue'
    if presetName ~= nil then
        for _, preset in ipairs(pool:Children()) do
            if getName(preset) == presetName then
                return preset
            end
        end
    end

    return nil
end

local function addReference(
    references,
    referenceKeys,
    poolName,
    presetName,
    presetNumber
)
    local key

    if presetName ~= nil then
        key = poolName
            .. "\001NAME\001"
            .. presetName
    else
        key = poolName
            .. "\001NO\001"
            .. presetNumber
    end

    if referenceKeys[key] then
        return
    end

    referenceKeys[key] = true

    table.insert(references, {
        poolName = poolName,
        presetName = presetName,
        presetNumber = presetNumber
    })
end

local function extractPresetReferences(
    cue,
    exportPath,
    filename
)
    local separator = GetPathSeparator()
    local fullPath =
        exportPath .. separator .. filename

    local references = {}
    local referenceKeys = {}

    if FileExists(fullPath) then
        os.remove(fullPath)
    end

    if cue:Export(exportPath, filename) ~= true then
        ErrPrintf(
            "XML export failed: %s",
            filename
        )

        return references
    end

    local file, openError =
        io.open(fullPath, "r")

    if file == nil then
        ErrPrintf(
            "Unable to read XML file: %s",
            tostring(openError)
        )

        os.remove(fullPath)
        return references
    end

    local xml = file:read("*a")
    file:close()

    local deleted, deleteError =
        os.remove(fullPath)

    if deleted ~= true then
        ErrPrintf(
            "Unable to delete XML file: %s",
            tostring(deleteError)
        )
    end

    if xml == nil or xml == "" then
        return references
    end

    -- Named Preset:
    -- AbsPreset="gColor.&apos;8R Blue&apos;"
    for poolName, encodedPresetName in xml:gmatch(
        'AbsPreset="g([^%."]+)%.&apos;(.-)&apos;"'
    ) do
        addReference(
            references,
            referenceKeys,
            poolName,
            decodeXml(encodedPresetName),
            nil
        )
    end

    -- Preset without a label:
    -- AbsPreset="gGobo.4"
    for poolName, presetNumber in xml:gmatch(
        'AbsPreset="g([^%."]+)%.([%d%.]+)"'
    ) do
        addReference(
            references,
            referenceKeys,
            poolName,
            nil,
            presetNumber
        )
    end

    return references
end

local function findExactGroups(
    cueSelection,
    cueCount,
    groups
)
    local matches = {}

    if cueCount == 0 then
        return matches
    end

    for _, group in ipairs(groups) do
        local groupSelection, groupCount =
            selectAndRead(
                "SelFix " .. group:ToAddr()
            )

        if groupCount == cueCount
            and selectionsAreIdentical(
                cueSelection,
                groupSelection
            )
        then
            table.insert(matches, group)
        end
    end

    return matches
end

local function getPresetDisplayName(
    reference,
    preset
)
    if reference.presetName ~= nil then
        return reference.presetName
    end

    local presetName = getName(preset)

    if presetName ~= nil then
        return presetName
    end

    return string.format(
        "%s %s",
        reference.poolName,
        reference.presetNumber
    )
end

local function recipeAlreadyExists(
    part,
    recipeName
)
    if part == nil then
        return false
    end

    for _, recipe in ipairs(part:Children()) do
        if recipe:GetClass() == "StandardRecipe"
            and getName(recipe) == recipeName
        then
            return true
        end
    end

    return false
end

local function createStandardRecipe(
    sequenceNumber,
    cueNumber,
    recipeNumber,
    group,
    preset,
    recipeName
)
    local targetAddress = string.format(
        "Sequence %s Cue %g Part 0.%d",
        sequenceNumber,
        cueNumber,
        recipeNumber
    )

    local storeCommand = string.format(
        "Store Type 'StandardRecipe' %s " ..
        "/Merge /PhaserData='No'",
        targetAddress
    )

    local selectionCommand = string.format(
        "Assign %s At %s Property 'Selection'",
        group:ToAddr(),
        targetAddress
    )

    local presetCommand = string.format(
        "Assign %s At %s Property 'Preset'",
        preset:ToAddr(),
        targetAddress
    )

    local nameCommand = string.format(
        "Set %s Property 'Name' %s",
        targetAddress,
        quoteCommandText(recipeName)
    )

    Cmd(storeCommand)
    Cmd(selectionCommand)
    Cmd(presetCommand)
    Cmd(nameCommand)

    Printf(
        "Recipe created: %s",
        targetAddress
    )

    return true
end

local function removeHardValues(
    sequenceNumber,
    cueNumber,
    group,
    preset
)
    Printf(
        "Removing hard-coded values: %s + %s",
        group:ToAddr(),
        preset:ToAddr()
    )

    Cmd("ClearAll")
    Cmd(group:ToAddr())
    Cmd(preset:ToAddr())

    Cmd(
        string.format(
            "Store Sequence %s Cue %g /Remove",
            sequenceNumber,
            cueNumber
        )
    )

    Cmd("ClearAll")
end

local function cookCue(
    sequenceNumber,
    cueNumber
)
    Printf(
        "Cook Sequence %s Cue %g /Merge",
        sequenceNumber,
        cueNumber
    )

    Cmd(
        string.format(
            "Cook Sequence %s Cue %g /Merge",
            sequenceNumber,
            cueNumber
        )
    )
end

local function main()
    local sequence = SelectedSequence()

    if sequence == nil then
        ErrPrintf(
            "No sequence selected."
        )

        return
    end

    local sequenceNumber =
        tostring(sequence:Get("NO"))

    local groups =
        DataPool().Groups:Children()

    local exportPath =
        GetPath(
            Enums.PathType.UserSequences
        )

    Printf("========================================")
    Printf(
        "CONVERSION: %s",
        getDisplayName(sequence)
    )
    Printf("========================================")

    local totalCreated = 0
    local totalExisting = 0
    local totalConverted = 0

    for _, cue in ipairs(sequence:Children()) do
        local cueName = getDisplayName(cue)

        if cue:GetClass() == "Cue"
            and cueName ~= "OffCue"
            and cueName ~= "CueZero"
        then
            local cueNumberInternal =
                tonumber(cue:Get("NO"))

            if cueNumberInternal ~= nil then
                local cueNumber =
                    cueNumberInternal / 1000

                Printf("")
                Printf("----------------------------------------")
                Printf(
                    "Cue %g: %s",
                    cueNumber,
                    cueName
                )

                local cueCommand = string.format(
                    "SelFix Cue %g Sequence %s",
                    cueNumber,
                    sequenceNumber
                )

                local cueSelection, cueCount =
                    selectAndRead(cueCommand)

                Printf(
                    "Fixtures detected: %d",
                    cueCount
                )

                local matchingGroups =
                    findExactGroups(
                        cueSelection,
                        cueCount,
                        groups
                    )

                local filename = string.format(
                    "CueToRecipe_tmp_Seq%s_Cue%s.xml",
                    sequenceNumber,
                    tostring(cueNumberInternal)
                )

                local presetReferences =
                    extractPresetReferences(
                        cue,
                        exportPath,
                        filename
                    )

                if #matchingGroups == 0 then
                    Printf(
                        "Cue skipped: no exact Group match."
                    )
                elseif #presetReferences == 0 then
                    Printf(
                        "Cue skipped: no referenced Preset."
                    )
                else
                    local part =
                        cue:Children()[1]

                    local nextRecipeNumber = 1

                    if part ~= nil then
                        nextRecipeNumber =
                            #part:Children() + 1
                    end

                    local conversions = {}

                    for _, group in ipairs(
                        matchingGroups
                    ) do
                        for _, reference in ipairs(
                            presetReferences
                        ) do
                            local preset = findPreset(
                                reference.poolName,
                                reference.presetName,
                                reference.presetNumber
                            )

                            if preset == nil then
                                ErrPrintf(
                                    "Preset not found: %s.%s",
                                    reference.poolName,
                                    tostring(
                                        reference.presetName
                                        or reference.presetNumber
                                    )
                                )
                            else
                                local presetDisplayName =
                                    getPresetDisplayName(
                                        reference,
                                        preset
                                    )

                                local recipeName =
                                    getDisplayName(group)
                                    .. " - "
                                    .. presetDisplayName

                                local recipeReady = false

                                if recipeAlreadyExists(
                                    part,
                                    recipeName
                                ) then
                                    Printf(
                                        "Recipe already exists: %s",
                                        recipeName
                                    )

                                    totalExisting =
                                        totalExisting + 1

                                    recipeReady = true
                                else
                                    recipeReady =
                                        createStandardRecipe(
                                            sequenceNumber,
                                            cueNumber,
                                            nextRecipeNumber,
                                            group,
                                            preset,
                                            recipeName
                                        )

                                    if recipeReady then
                                        totalCreated =
                                            totalCreated + 1

                                        nextRecipeNumber =
                                            nextRecipeNumber + 1
                                    end
                                end

                                if recipeReady then
                                    table.insert(
                                        conversions,
                                        {
                                            group = group,
                                            preset = preset
                                        }
                                    )
                                end
                            end
                        end
                    end

                    if #conversions > 0 then
                        for _, conversion in ipairs(
                            conversions
                        ) do
                            removeHardValues(
                                sequenceNumber,
                                cueNumber,
                                conversion.group,
                                conversion.preset
                            )
                        end

                        cookCue(
                            sequenceNumber,
                            cueNumber
                        )

                        totalConverted =
                            totalConverted + 1
                    else
                        Printf(
                            "No values were removed."
                        )
                    end
                end
            end
        end
    end

    Cmd("ClearAll")

    Printf("")
    Printf("========================================")
    Printf(
        "Recipes created    : %d",
        totalCreated
    )
    Printf(
        "Existing recipes   : %d",
        totalExisting
    )
    Printf(
        "Cues converted     : %d",
        totalConverted
    )
    Printf("Conversion completed.")
    Printf("========================================")
end

return main
