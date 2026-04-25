# Audit Log — Output 2.1: File Parameters Description

> **Input:** `output/02_file_summary.md`
> **Date:** 2026-04-23
> **Analyst role:** Senior software architect, Camtek Falcon BIS platform
> **Scope:** All 77 file patterns identified in Section 1 of 02_file_summary.md

---

## How to read this document

Each file pattern gets its own section containing:
- A two-sentence **purpose** description
- A **parameters table** with columns: Parameter Name · Section · Description · Accepted Values / Type · Example Value

Placeholder tokens in file paths: `<JobName>` = any job folder (e.g., `Diced_10.0.4511`), `<Setup>` = setup folder (e.g., `S1`), `<R>` = recipe folder (e.g., `R1`), `<zone>` = zone name (e.g., `PostProcess`), `<guid>` = GUID string.

Analysis is based strictly on observed file content. Where a file was not found or is binary, parameters are marked `UNKNOWN`.

---

## File 1 — `c:\job\status.ini`

**Purpose:** Global machine-state singleton updated continuously by Falcon.Net on every program/state transition. Records which job, product, and recipe are currently active on the machine.

| Parameter Name | Section | Description | Accepted Values / Type | Example Value |
|---|---|---|---|---|
| `ProgramName` | `[UC_PROGRAM]` | Name of the currently loaded machine program | String | `300mm` |
| `ProductName` | `[UC_PROGRAM]` | Name of the active job/product | String | `ValidationJob` |
| `RecipeName` | `[UC_PROGRAM]` | Name of the active recipe | String | `x5` |

---

## File 2 — `c:\job\<JobName>\Metadata.ini`

**Purpose:** Top-level job identity file storing the human-readable job name, a unique GUID, version counter, and an optional free-text tag. Written by RMS at job creation; not modified during normal operation.

| Parameter Name | Section | Description | Accepted Values / Type | Example Value |
|---|---|---|---|---|
| `name` | `[General]` | Human-readable job name | String | `Diced_10.0.4511` |
| `Id` | `[General]` | Unique GUID identifying this job | UUID string | `46a4c3bf-4464-4070-b41b-4939a9842d63` |
| `Version` | `[General]` | Job schema version counter | Integer | `1` |
| `JobTag` | `[General]` | Optional free-text label for the job | String (may be empty) | *(empty)* |

---

## File 3 — `c:\job\<JobName>\<Setup>\Metadata.ini`

**Purpose:** Setup-level identity file recording the setup name, GUID, version, and which recipe was last active in this setup. Written by RMS at setup creation; `LastActiveRecipe` updated on each recipe load.

| Parameter Name | Section | Description | Accepted Values / Type | Example Value |
|---|---|---|---|---|
| `name` | `[General]` | Human-readable setup name | String | `S1` |
| `Id` | `[General]` | Unique GUID identifying this setup | UUID string | `f0e6ec38-de8f-4dc7-b0a4-c114aed4418a` |
| `Version` | `[General]` | Setup schema version counter | Integer | `1` |
| `LastActiveRecipe` | `[General]` | Name of the last recipe that was loaded in this setup | String | `R1` |

---

## File 4 — `c:\job\<JobName>\<Setup>\MultiRecipe.ini`

**Purpose:** Defines multi-recipe scan orchestration for a setup — which recipes are active, their execution order, merge strategy, per-recipe alignment and sampling flags, and AQL criteria per scan. Written by RMS at setup creation.

| Parameter Name | Section | Description | Accepted Values / Type | Example Value |
|---|---|---|---|---|
| `MergingThreadCount` | `[Scan]` | Number of parallel threads for result merging | Integer ≥ 0 | `0` |
| `doSeparateRecipe` | `[Scan]` | Run recipes as separate scan passes (vs. interleaved) | Boolean 0/1 | `0` |
| `DoGrabAfterMerge` | `[Scan]` | Perform defect image grab after result merge | Boolean 0/1 | `0` |
| `Recipes` | `[Scan]` | Comma-separated enable flags for each recipe slot | Comma-separated integers | `0,1,` |
| `FieldCount` | `[Scan]` | Number of data fields in each recipe definition line | Integer | `8` |
| `RecipesPos` | `[Scan]` | Position index of each recipe in the scan sequence | Comma-separated integers | `1,2,` |
| `RecipesMerge` | `[Scan]` | Whether each recipe participates in result merge | Comma-separated Boolean 0/1 | `0,0,` |
| `RunWaferAlignment` | `[Scan]` | Per-recipe wafer alignment trigger (-1=auto, 0=skip) | Comma-separated integers | `-1,0,` |
| `RecipesSampling` | `[Scan]` | Per-recipe sampling scan flag | Comma-separated Boolean 0/1 | `0,0,` |
| `RecipesDynamic` | `[Scan]` | Per-recipe dynamic scanning flag | Comma-separated Boolean 0/1 | `0,0,` |
| `BatchStatus` | `[Scan]` | Per-recipe batch processing status | Comma-separated integers | `0,0,` |
| `recipe_N` | `[Scan]` | Full recipe-slot definition: order, name, and 6 option fields | Comma-separated string | `-1,R1,-1,0,-1,0,100,1` |
| `Version` | `[General]` | File format version | String | `1.0.0` |
| `Scan1` | `[WaferAQL2]` | AQL criteria string for scan 1 | String (may be empty) | *(empty)* |
| `Scan2` | `[WaferAQL2]` | AQL criteria string for scan 2 | String (may be empty) | *(empty)* |

---

## File 5 — `c:\job\<JobName>\<Setup>\DefectsClustering.ini`

**Purpose:** Controls whether defects are grouped into clusters after scanning, and specifies the clustering algorithm, proximity threshold, and defect sort order for display and reporting. Written by RMS at setup creation.

| Parameter Name | Section | Description | Accepted Values / Type | Example Value |
|---|---|---|---|---|
| `Enabled` | `[General]` | Master switch — enable or disable defect clustering | Boolean 0/1 | `0` |
| `ClusteringAfterMerge` | `[General]` | Apply clustering after multi-recipe result merge | Boolean 0/1 | `0` |
| `Distance` | `[General]` | Maximum center-to-center distance (µm) to consider two defects as one cluster | Float ≥ 0 | `0` |
| `SelectedFirstSortingList` | `[General]` | Primary sort field for defect list | String enum (`Priority`, `Area`, `Class`, …) | `Priority` |
| `SelectedSecondSortingList` | `[General]` | Secondary sort field for defect list | String enum | `Area` |
| `SelectedFirstSortingListOrder` | `[General]` | Sort direction for primary field | `Ascending` / `Descending` | `Ascending` |
| `SelectedSecondSortingListOrder` | `[General]` | Sort direction for secondary field | `Ascending` / `Descending` | `Ascending` |
| `DefectsClusteringAlgMode` | `[General]` | Clustering algorithm mode selector | Integer | `0` |

---

## File 6 — `c:\job\<JobName>\<Setup>\ProductionInfo.ini`

**Purpose:** Accumulates per-wafer production statistics (defect counts, die yield ratios, class hit counts, batch pass count) updated by RMS after each wafer scan. Reset at job creation.

| Parameter Name | Section | Description | Accepted Values / Type | Example Value |
|---|---|---|---|---|
| `WaferDefectsCount` | `[General]` | Total defect count on the last scanned wafer | Integer ≥ 0 | `0` |
| `WaferDefectDiceRatio` | `[General]` | Fraction of dice on last wafer that have at least one defect | Float 0.0–1.0 | `0.0000` |
| `WaferDefectClassId` | `[General]` | Defect class ID with the highest occurrence on last wafer | Integer | `0` |
| `WaferDefectClassIdCount` | `[General]` | Count of defects in the dominant class | Integer ≥ 0 | `0` |
| `BatchPassWafersCount` | `[General]` | Cumulative count of wafers that passed yield criteria in the current batch | Integer ≥ 0 | `0` |

---

## File 7 — `c:\job\<JobName>\<Setup>\ScanCondition.ini`

**Purpose:** Optional gate that can block scanning based on an external or internal condition. Contains a single active/inactive flag; when inactive the condition is ignored.

| Parameter Name | Section | Description | Accepted Values / Type | Example Value |
|---|---|---|---|---|
| `IsActive` | `[General]` | Whether the scan condition check is enforced | Boolean 0/1 | `0` |

---

## File 8 — `c:\job\<JobName>\<Setup>\Wafer2Table.ini` *(setup level)*

**Purpose:** Stores the 2×3 affine transformation matrix mapping wafer coordinates to chuck/stage coordinates, computed after wafer alignment, along with per-anchor residuals. Updated by AOI_Main on each alignment event; used as the active transform for all stage moves.

| Parameter Name | Section | Description | Accepted Values / Type | Example Value |
|---|---|---|---|---|
| `Wafer2Table_X` | `[WAFER ALIGNMENT]` | X-row of the 2×3 affine matrix (R11, R12, Tx) | Three space-separated floats | `0.9999944815  -0.0062677412  106354.8850214472` |
| `Wafer2Table_Y` | `[WAFER ALIGNMENT]` | Y-row of the 2×3 affine matrix (R21, R22, Ty) | Three space-separated floats | `0.0064146993  0.9999694163  126219.3883009121` |
| `Rotate  w2t` | `[WAFER ALIGNMENT]` | Net rotation angle of wafer-to-table transform (degrees) | Float | `0.367541` |
| `Shear   w2t` | `[WAFER ALIGNMENT]` | Shear component of the transform | Float | `-0.008429` |
| `Stretch w2t` | `[WAFER ALIGNMENT]` | Scale factors along X and Y axes | Two floats | `1.0000141  0.9999900` |
| `Offset  w2t` | `[WAFER ALIGNMENT]` | Translation offset (X, Y) in µm | Two floats | `106354.885  126219.388` |
| `StdAffine` | `[WAFER ALIGNMENT]` | RMS residual of the full affine fit (µm) | Float ≥ 0 | `10.66` |
| `StdOrtho` | `[WAFER ALIGNMENT]` | RMS residual of the orthogonal (rigid) fit (µm) | Float ≥ 0 | `10.43` |
| `Apply` | `[LOCAL_CORRECTION]` | Whether local correction overlay is applied on top of the global transform | Boolean 0/1 | `0` |
| `SaveTime` | `[General]` | Timestamp when this alignment was written | Date/time string (`MM/DD/YY HH:MM:SS`) | `03/03/26 19:02:05` |
| `Count` | `[ANCHOR POINTS]` | Number of anchor points used in alignment | Integer | `8` |
| `Anchor_N` | `[ANCHOR POINTS]` | Per-anchor data: Chuck_X, Chuck_Y, Delta_X, Delta_Y, Theta | Five space-separated floats per row | `-108591.330565 -124783.356514 -1451.809842 750.915468 -0.73509692` |

---

## File 9 — `c:\job\<JobName>\<Setup>\DefaultWafer2Table.ini` *(setup level)*

**Purpose:** Baseline wafer-to-table transform stored at setup creation time; used as the initial transform before any live alignment run has been performed. Identical structure to `Wafer2Table.ini`.

| Parameter Name | Section | Description | Accepted Values / Type | Example Value |
|---|---|---|---|---|
| *(same parameters as File 8 — Wafer2Table.ini)* | | | | |

---

## File 10 — `c:\job\<JobName>\<Setup>\DieAlignment.dat_block.ini` *(setup level)*

**Purpose:** Defines the die grid block layout — die count, row/column indices, physical position, and size in µm — used as the baseline for die alignment algorithms at setup scope. Written by RMS at setup creation.

| Parameter Name | Section | Description | Accepted Values / Type | Example Value |
|---|---|---|---|---|
| `IsMultiIndex` | `[General]` | Whether a multi-index die layout is in use | Boolean 0/1 | `0` |
| `DieCount` | `[General]` | Number of die entries defined in this file | Integer ≥ 1 | `1` |
| `Row` | `[Die_N]` | Row index of this die in the grid | Integer ≥ 0 | `0` |
| `Col` | `[Die_N]` | Column index of this die in the grid | Integer ≥ 0 | `0` |
| `PosX` | `[Die_N]` | X position of this die origin (µm) | Float | `0.000` |
| `PosY` | `[Die_N]` | Y position of this die origin (µm) | Float | `0.000` |
| `SizeX` | `[Die_N]` | Die width (µm) | Float > 0 | `4117.000` |
| `SizeY` | `[Die_N]` | Die height (µm) | Float > 0 | `19645.000` |

---

## File 11 — `c:\job\<JobName>\<Setup>\WaferMapRecipe.ini` *(setup level)*

**Purpose:** Controls wafer map import and update settings at setup scope — whether external maps are ingested, how fiducials are matched, and the map update policy. Shares identical structure with the recipe-level version (File 45).

| Parameter Name | Section | Description | Accepted Values / Type | Example Value |
|---|---|---|---|---|
| *(same parameters as File 45 — WaferMapRecipe.ini recipe level)* | | | | |

---

## File 12 — `c:\job\<JobName>\<Setup>\Recipes\<R>\Recipe.ini`

**Purpose:** Top-level recipe control file governing auto-cycle behavior — autofocus and clean-reference frequencies, post-processing flags, and recipe identity. Loaded by RMS/Falcon.Net on every recipe load; `[AutoCycle]` fields govern per-wafer automation.

| Parameter Name | Section | Description | Accepted Values / Type | Example Value |
|---|---|---|---|---|
| `AutoFocusBeforeAlignment` | `[AutoCycle]` | Trigger autofocus before the alignment step | Boolean 0/1 | `0` |
| `AutoFocusEvery` | `[AutoCycle]` | Autofocus run frequency (0=None, 1=Every Wafer, 2=Every Lot, …) | Integer enum | `1` |
| `CleanReferenceEvery` | `[AutoCycle]` | Clean-reference creation frequency (1=None, 3=Every Wafer, …) | Integer enum | `3` |
| `UnloadToAnotherCassette` | `[AutoCycle]` | Unload wafers to cassette B after scan | Boolean 0/1 | `0` |
| `NewCleanReferenceOption` | `[AutoCycle]` | Clean reference creation method option | Integer | `1` |
| `StoreSamplingHeight` | `[AutoCycle]` | Save height data collected during sampling scans | Boolean 0/1 | `0` |
| `EnableDieLevelPostProcessing` | `[AutoCycle]` | Enable die-level post-processing algorithms | Boolean 0/1 | `1` |
| `ImportResults` | `[AutoCycle]` | Import external KLARF results during auto-cycle | Boolean 0/1 | `0` |
| `SaveReferenceInResults` | `[AutoCycle]` | Save reference images inside scan result folder | Boolean 0/1 | `0` |
| `CleanRefFreq` | `[AutoCycle]` | Clean reference every N wafers (0 = every wafer) | Integer ≥ 0 | `0` |
| `CleanRefCounter` | `[AutoCycle]` | Internal counter tracking wafers since last clean reference | Integer ≥ 0 | `0` |
| `Recipe Name` | `[General]` | Recipe name identifier | String | `R1` |
| `LastCam` | `[General]` | Index of the last camera used in this recipe | Integer | `3` |
| `LastCamZoom` | `[General]` | Zoom level of the last camera used | Float | `2.5` |

---

## File 13 — `c:\job\<JobName>\<Setup>\Recipes\<R>\ProductInfo.ini`

**Purpose:** Stores all product-level wafer parameters: die geometry, pitch, wafer diameter, scan flags, robot configuration, reference die coordinates, and surface mapping mode. Written at recipe creation; applied at every recipe load by RMS and AOI_Main.

| Parameter Name | Section | Description | Accepted Values / Type | Example Value |
|---|---|---|---|---|
| `SearchUseDefault` | `[AutoFocus]` | Use default autofocus search parameters | Boolean 0/1 | `1` |
| `ScanDelta` | `[AutoFocus]` | Z-delta for autofocus scan range (µm) | Float | `0` |
| `OnLimitViolationAction` | `[AutoFocus]` | Action when focus limit is violated | Integer enum | `0` |
| `FocusVAriationLimit` | `[AutoFocus]` | Maximum allowed focus variation (µm) | Float | `0` |
| `LimitFocusVariation` | `[AutoFocus]` | Enable focus variation limit check | Boolean 0/1 | `0` |
| `RetriesCount` | `[AutoFocus]` | Number of focus retries on failure | Integer ≥ 0 | `0` |
| `ExportFlatPos` | `[GENERAL]` | Export wafer flat/notch position to results | Boolean 0/1 | `0` |
| `WaferTypeId` | `[GENERAL]` | Wafer type label string | String (`Diced`, `BGA`, …) | `Diced` |
| `Mag` | `[GENERAL]` | Scan magnification | Float | `10.000000` |
| `InkDotMag` | `[GENERAL]` | Ink dot scan magnification (-1 = use scan mag) | Float | `-1.000000` |
| `Scan2DPixelSize` | `[GENERAL]` | 2D scan effective pixel size (µm) | Float > 0 | `0.8577` |
| `SkipPreAligner` | `[GENERAL]` | Skip the pre-aligner step for this recipe | Boolean 0/1 | `0` |
| `AlignmentDieCol` | `[GENERAL]` | Column index of the reference alignment die | Integer | `21` |
| `AlignmentDieRow` | `[GENERAL]` | Row index of the reference alignment die | Integer | `1` |
| `CustomerName` | `[GENERAL]` | Customer label for this product | String | `Internal` |
| `DuplicateRangeX` | `[GENERAL]` | Duplicate defect merge range in X (µm) | Integer | `3` |
| `DuplicateRangeY` | `[GENERAL]` | Duplicate defect merge range in Y (µm) | Integer | `3` |
| `Slot` | `[GENERAL]` | FOUP slot number | Integer | `1` |
| `Cassette` | `[GENERAL]` | FOUP cassette number | Integer | `1` |
| `IsPanel` | `[Geometric]` | Product is a panel (not round wafer) | Boolean 0/1 | `0` |
| `IsMultiIndex` | `[Geometric]` | Multi-index die layout active | Boolean 0/1 | `0` |
| `DieSelectedSize_X` | `[Geometric]` | Actual measured die width (µm) | Float > 0 | `3530.5884` |
| `DieSelectedSize_Y` | `[Geometric]` | Actual measured die height (µm) | Float > 0 | `16848.2150` |
| `CustomerDiePitch_X` | `[Geometric]` | Customer-specified die pitch in X (µm) | Float > 0 | `3607.5435` |
| `CustomerDiePitch_Y` | `[Geometric]` | Customer-specified die pitch in Y (µm) | Float > 0 | `16927.8925` |
| `Diameter` | `[Geometric]` | Wafer diameter (µm) | Float > 0 | `200000.0000` |
| `Flat Size` | `[Geometric]` | Flat/notch size | Float | `1.0000` |
| `NotchFlat` | `[Geometric]` | Notch (1) or flat (0) present | Integer 0/1 | `1` |
| `Flat Pos` | `[Geometric]` | Flat/notch orientation index | Integer | `0` |
| `Cols` | `[Geometric]` | Number of die columns in grid | Integer > 0 | `58` |
| `Rows` | `[Geometric]` | Number of die rows in grid | Integer > 0 | `14` |
| `XDieIndex` | `[Geometric]` | Die pitch index in X (µm) | Float | `3613.4000` |
| `YDieIndex` | `[Geometric]` | Die pitch index in Y (µm) | Float | `16933.0000` |
| `XDieSize` | `[Geometric]` | Die size in X (µm) | Float | `3530.5884` |
| `YDieSize` | `[Geometric]` | Die size in Y (µm) | Float | `16848.2150` |
| `Name` | `[RobotSetup]` | Robot/EFEM configuration file name | String | `PD_8_106448_ARC.cfg` |
| `PhysicalDiameterInInches` | `[WaferParam]` | Wafer physical diameter (inches) | Float | `8.0000` |
| `WaferType` | `[WaferParam]` | Wafer type code | Integer | `0` |
| `WaferThickness` | `[WaferParam]` | Wafer thickness (µm) | Integer | `3000` |
| `3D Method` | `[WaferParam]` | 3D measurement method code | Integer | `0` |
| `Co-planarity method` | `[WaferParam]` | Coplanarity calculation method code (-1=auto) | Integer | `-1` |
| `Wafer ID Format` | `[WaferParam]` | Wafer ID format code | Integer | `200` |
| `DieTopLeft_IsValid` | `[ReferenceDefinition]` | Whether top-left reference die corner is valid | Boolean 0/1 | `1` |
| `DieTopLeft_X` | `[ReferenceDefinition]` | X coordinate of top-left reference die corner (µm) | Float | `175516.7133` |
| `DieTopLeft_Y` | `[ReferenceDefinition]` | Y coordinate of top-left reference die corner (µm) | Float | `293323.6847` |
| `DieTopRight_IsValid` | `[ReferenceDefinition]` | Validity flag for top-right corner | Boolean 0/1 | `1` |
| `DieTopRight_X` / `_Y` | `[ReferenceDefinition]` | Top-right reference die corner (µm) | Float | `171986.4000` / `293343.4437` |
| `DieBottomRight_IsValid` | `[ReferenceDefinition]` | Validity flag for bottom-right corner | Boolean 0/1 | `1` |
| `DieBottomRight_X` / `_Y` | `[ReferenceDefinition]` | Bottom-right reference die corner (µm) | Float | `171886.8812` / `276496.5720` |
| `NextDieTopLeft_IsValid` | `[ReferenceDefinition]` | Validity flag for next die top-left corner | Boolean 0/1 | `1` |
| `NextDieTopLeft_X` / `_Y` | `[ReferenceDefinition]` | Next die top-left corner (µm) | Float | `171808.8890` / `276413.8673` |
| `MaxPos_Z` | `[Template]` | Maximum allowed Z height (µm) | Float | `81250.0000` |
| `ChuckOffset_X` / `_Y` | `[Template]` | Chuck offset for this recipe (µm) | Float | `0.0000` |
| `Col` / `Row` | `[Template]` | Template reference die column/row | Integer | `21` / `1` |
| `SaveWaferSurfaceInChuckSpace` | `[WaferSurface]` | Save wafer surface data in chuck coordinate space | Boolean 0/1 | `0` |
| `ImportFromSetupLevel` | `[WaferSurface]` | Import wafer surface data from setup level | Boolean 0/1 | `0` |
| `eSCAN_2D` … `eSCAN_FOCUS_EVALUATION_BY_2D` | `[DisableMappingSurfacesDuringScan]` | Per-scan-mode disable flag for surface mapping | Boolean 0/1 | `0` |

---

## File 14 — `c:\job\<JobName>\<Setup>\Recipes\<R>\Waferinfo.ini`

**Purpose:** Configures wafer handling and scan automation settings — robot pre-aligner rotation, hardware dependency flags, auto-cycle mode, and OCR/ink-dot options. Loaded by RMS/AOI_Main at recipe load.

| Parameter Name | Section | Description | Accepted Values / Type | Example Value |
|---|---|---|---|---|
| `Rotation` | `[Robot]` | Pre-aligner rotation angle (degrees) | Integer (typically 0/90/180/270) | `90` |
| `SideUp` | `[Robot]` | Wafer side orientation (1=front up) | Integer 0/1 | `1` |
| `key_minarea` | `[General]` | Minimum defect area filter key | Integer | `0` |
| `hd_cmm` | `[General]` | CMM hardware dependency flag | Boolean `True`/`False` | `False` |
| `hd_alignment` | `[General]` | Alignment hardware dependency flag | Boolean `True`/`False` | `True` |
| `hd_scan` | `[General]` | Scan hardware dependency flag | Boolean `True`/`False` | `True` |
| `hd_robot` | `[General]` | Robot hardware dependency flag | Boolean `True`/`False` | `False` |
| `hd_verification` | `[General]` | Verification hardware dependency flag | Boolean `True`/`False` | `True` |
| `hd_scanresult` | `[General]` | Scan result hardware dependency flag | Boolean `True`/`False` | `True` |
| `key_quickAlign` | `[General]` | Use quick alignment mode | Boolean `True`/`False` | `True` |
| `ScanService` | `[General]` | Scan service mode code | Integer | `0` |
| `key_autoverify` | `[General]` | Enable automatic verification after scan | Boolean `True`/`False` | *(empty/False)* |
| `key_auto` | `[General]` | Enable full auto-cycle mode | Boolean `True`/`False` | `True` |
| `key_semiauto` | `[General]` | Enable semi-auto mode | Boolean `True`/`False` | `False` |
| `key_WaferIdReading` | `[General]` | Enable wafer ID (OCR) reading | Boolean `True`/`False` | `False` |
| `key_verify` | `[General]` | Enable verification step in cycle | Boolean `True`/`False` | `False` |
| `InkBinList` | `[General]` | Comma-separated list of bins to ink | String (may be empty) | *(empty)* |
| `LimitNumberOfInkedDice` | `[General]` | Limit the count of dice to ink per wafer | Boolean 0/1 | `0` |
| `Name` | `[Recipe]` | Recipe name (cross-reference) | String | `R1` |
| `AutoCycleScan` | `[AutoCycleInfo]` | Auto-cycle scan count state | Integer ≥ 0 | `0` |

---

## File 15 — `c:\job\<JobName>\<Setup>\Recipes\<R>\Wafer2Table.ini` *(recipe level)*

**Purpose:** Recipe-level wafer-to-table affine alignment matrix; updated by AOI_Main on each recipe load onto a new wafer. Identical structure to the setup-level `Wafer2Table.ini`.

| Parameter Name | Section | Description | Accepted Values / Type | Example Value |
|---|---|---|---|---|
| *(same parameters as File 8 — Wafer2Table.ini setup level)* | | | | |

---

## File 16 — `c:\job\<JobName>\<Setup>\Recipes\<R>\Alignment.ini`

**Purpose:** Minimal file recording the coarse alignment completion status and the resulting rotation residual for the current recipe load. Written by AOI_Main on each recipe load.

| Parameter Name | Section | Description | Accepted Values / Type | Example Value |
|---|---|---|---|---|
| `CoarseAlignDone` | `[WAFER ALIGNMENT]` | Whether coarse alignment completed successfully | Boolean 0/1 | `0` |
| `Rotate  w2t` | `[WAFER ALIGNMENT]` | Wafer-to-table rotation from this alignment session (degrees) | Float | `0` |

---

## File 17 — `c:\job\<JobName>\<Setup>\Recipes\<R>\DefaultWafer2Table.ini` *(recipe level)*

**Purpose:** Default (baseline) wafer-to-table alignment stored at recipe creation time; serves as the initial transform before live alignment refines it. Identical structure to the setup-level `DefaultWafer2Table.ini`.

| Parameter Name | Section | Description | Accepted Values / Type | Example Value |
|---|---|---|---|---|
| *(same parameters as File 8 — Wafer2Table.ini)* | | | | |

---

## File 18 — `c:\job\<JobName>\<Setup>\Recipes\<R>\AlignmentData.ini`

**Purpose:** Defines alignment point configuration for the recipe — minimum match scores, affine enablement, number of points, and the precise wafer coordinates of each alignment point. Written at recipe creation; read every run.

| Parameter Name | Section | Description | Accepted Values / Type | Example Value |
|---|---|---|---|---|
| `MinScore` | `[General]` | Minimum pattern match score for alignment to succeed (0–100) | Integer 0–100 | `85` |
| `MinTargetScore` | `[General]` | Minimum target pattern score | Integer 0–100 | `0` |
| `IsAffineEnabled` | `[General]` | Use affine transform (vs. rigid) for alignment fit | Boolean 0/1 | `1` |
| `AlignPointsNum` | `[General]` | Number of alignment points used | Integer ≥ 1 | `8` |
| `ForceToGMF` | `[General]` | Force use of GMF matcher for all alignment points | Boolean 0/1 | `0` |
| `X` | `[Point_N]` | X coordinate of alignment point N in wafer space (µm) | Float | UNKNOWN (varies per recipe) |
| `Y` | `[Point_N]` | Y coordinate of alignment point N in wafer space (µm) | Float | UNKNOWN (varies per recipe) |
| `BlockIndex_Col` | `[Point_N]` | Die grid column index for this alignment point | Integer | `0` |
| `BlockIndex_Row` | `[Point_N]` | Die grid row index for this alignment point | Integer | `0` |
| `MinGoodModels` | `[SECOND_ALIGN]` | Minimum good model matches required for second-pass alignment | Integer ≥ 1 | `5` |

---

## File 19 — `c:\job\<JobName>\<Setup>\Recipes\<R>\AlignRtp.ini`

**Purpose:** Alignment run-time parameters controlling die and frame alignment algorithms — model scoring thresholds, GMF settings, die-tracker configuration, ROI sizes, and debug output flags. Written at recipe creation; read on every scan.

| Parameter Name | Section | Description | Accepted Values / Type | Example Value |
|---|---|---|---|---|
| `Die__MinModelSize` | `[DIE Alignment]` | Minimum model size (pixels) for die alignment | Integer ≥ 0 | `64` |
| `Die__MinScore` | `[DIE Alignment]` | Minimum die alignment match score (0–100) | Integer 0–100 | `65` |
| `Die__ExtraScanLength_um` | `[DIE Alignment]` | Extra scan margin added symmetrically (µm) | Float ≥ 0 | `0.0` |
| `Die__ExtraScanLength_X_um` | `[DIE Alignment]` | Extra scan margin in X direction (µm) | Float ≥ 0 | `0.0` |
| `Die__ExtraScanLength_Y_um` | `[DIE Alignment]` | Extra scan margin in Y direction (µm) | Float ≥ 0 | `0.0` |
| `Die__Uncertanty_um` | `[DIE Alignment]` | Global positional uncertainty tolerance (µm) | Integer > 0 | `150` |
| `Die__Uncertanty_X_um` | `[DIE Alignment]` | X-axis uncertainty override (-1 = use global) | Integer | `-1` |
| `Die__Uncertanty_Y_um` | `[DIE Alignment]` | Y-axis uncertainty override (-1 = use global) | Integer | `-1` |
| `Die__InspDiceOnly` | `[DIE Alignment]` | Restrict alignment to inspectable dice only | Boolean 0/1 | `1` |
| `Die__UseGMF` | `[DIE Alignment]` | Use GMF engine for die-level alignment | Boolean 0/1 | `1` |
| `ImageSmoothFactor` | `[DIE Alignment]` | Pre-processing smoothing factor applied to alignment images | Integer ≥ 0 | `0` |
| `Die__UseCrestForGMF` | `[DIE Alignment]` | Use CREST feature extraction in GMF matching | Boolean 0/1 | `0` |
| `Die__UseCrestForGmfModel` | `[DIE Alignment]` | Use CREST for GMF model creation | Boolean 0/1 | `1` |
| `Die__UseAffine` | `[DIE Alignment]` | Use affine transform in die alignment | Boolean 0/1 | `0` |
| `UP_ImageConverter` | `[DIE Alignment]` | UUID of the image pre-processor engine for alignment | UUID string | `306a7e84-3bae-4443-bedf-ea9321f61841` |
| `ModelFreeAlignment` | `[DIE Alignment]` | Use model-free alignment algorithm | Boolean 0/1 | `0` |
| `ModelFreeMinScore` | `[DIE Alignment]` | Minimum score for model-free alignment | Integer 0–100 | `80` |
| `ModelFreeAccuracySpeed` | `[DIE Alignment]` | Speed/accuracy trade-off for model-free (0=accurate) | Integer | `0` |
| `ModelFreeNoisePercent` | `[DIE Alignment]` | Noise tolerance percentage for model-free | Integer 0–100 | `25` |
| `DT_UsePredict` | `[DICE_TRACKER]` | Use predictive position tracking for dice | Boolean 0/1 | `0` |
| `DT_PosEstimationBase` | `[DICE_TRACKER]` | Position estimation base method | Integer | `1` |
| `DT_MaxStdForPrediction` | `[DICE_TRACKER]` | Max standard deviation for prediction validity (µm) | Integer > 0 | `30` |
| `DT_MaxPosError` | `[DICE_TRACKER]` | Maximum allowed position error (µm) | Integer > 0 | `2` |
| `DT_MinDice` | `[DICE_TRACKER]` | Minimum dice count required to start tracker | Integer ≥ 1 | `10` |
| `DT_MaxGap_Dice` | `[DICE_TRACKER]` | Maximum gap in dice count before tracker resets | Integer | `4` |
| `DT_MaxGap_Frames` | `[DICE_TRACKER]` | Maximum frame gap before tracker resets | Float | `5.0` |
| `DT_AffineEnabled` | `[DICE_TRACKER]` | Enable affine correction in tracker | Boolean 0/1 | `1` |
| `DT_IrregularDiceThreshold` | `[DICE_TRACKER]` | Score threshold below which a die is considered irregular | Integer 0–100 | `79` |
| `DT_IrregularDiceSizePerecentageExclude` | `[DICE_TRACKER]` | Percentage of irregular dice to exclude from tracking | Integer 0–100 | `90` |
| `RotateModel` | `[GENERAL]` | Allow model rotation during matching | Boolean 0/1 | `1` |
| `SeparateDice` | `[GENERAL]` | Process each die separately (vs. strip-based) | Boolean 0/1 | `1` |
| `AliasDelta_%` | `[GENERAL]` | Anti-alias margin percentage | Integer 0–100 | `25` |
| `RegModelFileName` | `[GENERAL]` | Filename of the die registration model | String | `DieMapRegPos.dat` |
| `UseRegReference` | `[GENERAL]` | Use the registration reference in alignment | Boolean 0/1 | `1` |
| `Frame_MinScore` | `[FRAME Alignment]` | Minimum frame alignment match score | Integer 0–100 | `100` |
| `Frame_Uncertanty_px` | `[FRAME Alignment]` | Frame alignment position uncertainty (pixels) | Integer > 0 | `16` |
| `Frame_MaxModelShift_px` | `[FRAME Alignment]` | Maximum allowed model shift for frame (pixels) | Integer > 0 | `7` |
| `Frame_UseDieLevelModels` | `[FRAME Alignment]` | Use die-level models for frame alignment | Boolean 0/1 | `1` |
| `GMF_PrefetchModels` | `[GMF Params]` | Pre-load GMF models before scanning starts | Boolean 0/1 | `1` |
| `GMF_SmoothFactor` | `[GMF Params]` | GMF image smoothing factor | Integer 0–100 | `75` |
| `GMF_TimeOut_ms` | `[GMF Params]` | GMF search timeout (ms) | Integer > 0 | `100` |
| `GMF_TargetScore` | `[GMF Params]` | GMF target match score (0 = use MinScore) | Integer 0–100 | `0` |
| `GMF_LockScale` | `[GMF Params]` | Lock scale during GMF matching | Boolean 0/1 | `0` |
| `GMF_FitErrorFactor` | `[GMF Params]` | GMF fit error tolerance factor | Integer | `75` |
| `GMF_MultiModel` | `[GMF Params]` | Use multiple GMF models per die | Boolean 0/1 | `0` |
| `GMF_UseGeometricControlled` | `[GMF Params]` | Use geometric-controlled GMF | Boolean 0/1 | `1` |
| `UseGMF` | `[System Params]` | Use GMF globally (overrides per-section flags) | Boolean 0/1 | `0` |
| `MinScoreRatio` | `[System Params]` | Minimum score ratio for alignment acceptance | Float 0.0–1.0 | `0.900000` |
| `MinStd` | `[System Params]` | Minimum standard deviation threshold | Float | `2.000000` |
| `MinError` | `[System Params]` | Minimum error threshold for alignment residuals | Float | `0.500000` |
| `Method` | `[System Params]` | Alignment fitting method code | Integer | `4` |
| `TransformType` | `[System Params]` | Transform type (2=affine, 1=rigid, …) | Integer | `2` |
| `MinPoints` | `[System Params]` | Minimum number of good alignment points | Integer ≥ 1 | `3` |
| `Rotate_Wafer` | `[System Params]` | Pre-computed wafer rotation value (radians) | Float | `-0.0064154` |
| `ROI_Size` | `[DIE_MAPPING]` | ROI size for die mapping (pixels) | Integer > 0 | `128` |
| `ROI_Offset` | `[DIE_MAPPING]` | ROI offset for die mapping | Integer | `0` |
| `WaferMap_MinScore` | `[DIE_MAPPING]` | Minimum score for wafer map die matching | Integer 0–100 | `50` |
| `IVP_Die_Uncertanty_um` | `[IVP Params]` | IVP die alignment uncertainty (µm) | Integer | `300` |
| `IVP_Die_MinScore` | `[IVP Params]` | IVP minimum die match score | Integer 0–100 | `100` |
| `IVP_GMF_TargetScore` | `[IVP Params]` | IVP GMF target score | Integer 0–100 | `80` |
| `Enable3DFrameAlignment` | `[3D Params]` | Enable 3D frame alignment | Boolean 0/1 | `0` |
| `BigBlockRowsNumber` | `[3D Params]` | Number of rows per big block in 3D alignment | Integer | `300` |
| `BigBlockColsNumber` | `[3D Params]` | Number of columns per big block | Integer | `450` |
| `MaxErrorPix` | `[3D Params]` | Maximum error in pixels for 3D alignment | Integer | `8` |
| `Save_PatFindRes` | `[Debug]` | Save pattern-find result images | Boolean 0/1 | `0` |
| `Save_DieAlignLog` | `[Debug]` | Save die alignment log | Boolean 0/1 | `0` |

---

## File 20 — `c:\job\<JobName>\<Setup>\Recipes\<R>\GlobalRTP.ini`

**Purpose:** Global run-time parameters governing the inspection algorithm across all zones — bump height spec limits, coplanarity method, defect export flags, morphology operations, frame re-alignment settings, GPU mode, and defect quota limits. Written at recipe creation; read every scan.

| Parameter Name | Section | Description | Accepted Values / Type | Example Value |
|---|---|---|---|---|
| `LSL_Height` | `[GLOBAL_RTP]` | Lower specification limit for bump height (µm) | Float | `100.000000` |
| `USL_Height` | `[GLOBAL_RTP]` | Upper specification limit for bump height (µm) | Float | `140.000000` |
| `NominalHeight` | `[GLOBAL_RTP]` | Nominal bump height (µm) | Float | `120.000000` |
| `BumpType` | `[GLOBAL_RTP]` | Bump type classification code | Integer | `1` |
| `CCS_Step` | `[GLOBAL_RTP]` | CCS height scan step size (µm) | Float | `3.000000` |
| `CCS_Step_Reference` | `[GLOBAL_RTP]` | CCS step used for reference creation | Integer | `3` |
| `CCS_Use_Raw_Reference` | `[GLOBAL_RTP]` | Use raw (non-processed) reference for CCS | Boolean 0/1 | `1` |
| `ExportDefect_IDD` | `[GLOBAL_RTP]` | Export IDD-class defects to results | Boolean 0/1 | `0` |
| `ExportDefect_Pad` | `[GLOBAL_RTP]` | Export pad-class defects | Boolean 0/1 | `0` |
| `ExportDefect_Prob` | `[GLOBAL_RTP]` | Export probabilistic defects | Boolean 0/1 | `0` |
| `ExportDefect_SB` | `[GLOBAL_RTP]` | Export solder ball defects | Boolean 0/1 | `0` |
| `ExportDefect_IVP` | `[GLOBAL_RTP]` | Export IVP defects | Boolean 0/1 | `0` |
| `ExportDefect_Edge` | `[GLOBAL_RTP]` | Export edge defects | Boolean 0/1 | `0` |
| `CoplanarityMethod` | `[GLOBAL_RTP]` | Coplanarity calculation method (1=Peak-to-Peak, 2=Peak-to-Avg, 3=Seated, 4=Global, 5=Neighbor) | Integer 1–5 | `1` |
| `PlanarityMax` | `[GLOBAL_RTP]` | Maximum allowed planarity deviation (µm) | Float > 0 | `12.000000` |
| `AdaptiveHistogram` | `[GLOBAL_RTP]` | Enable adaptive histogram normalization | Boolean 0/1 | `0` |
| `MaxHistogramOffsetInPercent` | `[GLOBAL_RTP]` | Maximum histogram offset percentage | Integer 0–100 | `80` |
| `AdaptiveHistogramMinPixelCount` | `[GLOBAL_RTP]` | Minimum pixel count for adaptive histogram | Integer | `32` |
| `MaxFaultsPerWafer` | `[GLOBAL_RTP]` | Maximum defects allowed per wafer before stopping | Integer > 0 | `200000` |
| `MaxFaultsPerDie` | `[GLOBAL_RTP]` | Maximum defects allowed per die | Integer > 0 | `2000` |
| `ReAlignFrame_Enable` | `[GLOBAL_RTP]` | Enable per-frame re-alignment during scan | Boolean 0/1 | `0` |
| `ReAlignFrame_MaxIterations` | `[GLOBAL_RTP]` | Maximum iterations for frame re-alignment | Integer ≥ 1 | `5` |
| `ReAlignFrame_MSEImprovementPercent` | `[GLOBAL_RTP]` | Minimum MSE improvement % to accept re-alignment | Float | `1` |
| `ReAlignFrame_NGC_Sigma` | `[GLOBAL_RTP]` | NGC sigma parameter for re-alignment | Integer | `10` |
| `ReAlignFrame_MinDieSize` | `[GLOBAL_RTP]` | Minimum die size (pixels) for re-alignment | Integer | `10` |
| `ReAlignFrame_MaxShiftPx` | `[GLOBAL_RTP]` | Maximum shift allowed per re-alignment iteration (pixels) | Float | `1.000000` |
| `ReAlignFrame_MaxRotationPx` | `[GLOBAL_RTP]` | Maximum rotation allowed per iteration (pixels) | Float | `1.000000` |
| `UseGPU` | `[GLOBAL_RTP]` | Enable GPU-accelerated processing | Boolean 0/1 | `0` |
| `DeviceID` | `[GLOBAL_RTP]` | GPU device ID to use | Integer ≥ 0 | `0` |
| `AdaptiveGpuEnabled` | `[GLOBAL_RTP]` | Enable adaptive GPU usage | Boolean 0/1 | `1` |
| `SkipAlignFailedDice` | `[GLOBAL_RTP]` | Skip dice where alignment failed | Boolean 0/1 | `0` |
| `OnlyLimitDefectsByQuota` | `[GLOBAL_RTP]` | Apply defect quota as sole stop criterion | Boolean 0/1 | `0` |
| `DuplicateRange_Pix` | `[GLOBAL_RTP]` | Duplicate defect merge range (pixels) | Float ≥ 0 | `0.000000` |
| `DuplicateRange_um` | `[GLOBAL_RTP]` | Duplicate defect merge range (µm) | Float ≥ 0 | `0.000000` |
| `ReAlignFrame_FastCAD` | `[SystemParams]` | Use fast CAD mode in frame re-alignment | Boolean 0/1 | `1` |

---

## File 21 — `c:\job\<JobName>\<Setup>\Recipes\<R>\Params_AlignRTP.ini`

**Purpose:** System-level copy of the alignment RTP parameters stored separately for consumption by AOI_Main. Contains an identical parameter set to `AlignRtp.ini` (File 19).

| Parameter Name | Section | Description | Accepted Values / Type | Example Value |
|---|---|---|---|---|
| *(same parameters as File 19 — AlignRtp.ini)* | | | | |

---

## File 22 — `c:\job\<JobName>\<Setup>\Recipes\<R>\Params_SystemInfo.ini`

**Purpose:** Camera and image-processing system parameters — sensor dimensions, pixel size, calibration file paths, IVP/CCS optic offsets, and offline verification settings. Written at recipe creation from machine calibration data; read by AOI_Main at every load.

| Parameter Name | Section | Description | Accepted Values / Type | Example Value |
|---|---|---|---|---|
| `Gain` / `GainFx` / `Offset` / `Distortion` | `[SystemParams]` | Calibration correction enable flags (Gain, Gain-FX, Offset, Distortion) | Boolean 0/1 | `0` |
| `SizeX` | `[SystemParams]` | Full camera frame width (pixels) | Integer > 0 | `1280` |
| `SizeY` | `[SystemParams]` | Full camera frame height (pixels) | Integer > 0 | `1280` |
| `OffsetX` | `[SystemParams]` | Frame read-out offset in X (pixels) | Integer ≥ 0 | `384` |
| `OffsetY` | `[SystemParams]` | Frame read-out offset in Y (pixels) | Integer ≥ 0 | `384` |
| `CameraType` | `[SystemParams]` | Camera hardware type code | Integer | `3` |
| `ImageSizeInBytes` | `[SystemParams]` | Total frame image size in bytes | Integer > 0 | `1638400` |
| `InspBlockType` | `[SystemParams]` | Inspection block type selector | Integer | `1` |
| `EffectiveFrameSizeX` | `[SystemParams]` | Effective inspection area width (pixels) | Integer > 0 | `1248` |
| `EffectiveFrameSizeY` | `[SystemParams]` | Effective inspection area height (pixels) | Integer > 0 | `1248` |
| `PixelSize_X` | `[SystemParams]` | Physical pixel size in X direction (µm/pixel) | Float > 0 | `0.8576509` |
| `PixelSize_Y` | `[SystemParams]` | Physical pixel size in Y direction (µm/pixel) | Float > 0 | `0.8576509` |
| `PixelSize_Z` | `[SystemParams]` | Z height step size (µm) | Float > 0 | `1.580000` |
| `Rotate_Camera` | `[SystemParams]` | Camera rotation correction angle (degrees) | Float | `0.001000` |
| `FlipInspection` | `[SystemParams]` | Flip the inspection image orientation | Boolean 0/1 | `0` |
| `ApplyGainOffset` | `[SystemParams]` | Apply gain/offset calibration correction | Boolean 0/1 | `1` |
| `ApplyDistortion` | `[SystemParams]` | Apply distortion calibration correction | Boolean 0/1 | `1` |
| `SmoothRefImage` | `[SystemParams]` | Smooth the reference image before inspection | Boolean 0/1 | `0` |
| `MaxRefTilesSpace` | `[SystemParams]` | Maximum reference tile buffer count | Integer > 0 | `60` |
| `Insp2RefDelta` | `[SystemParams]` | Inspection-to-reference alignment delta threshold | Integer | `45` |
| `Insp2InspDelta` | `[SystemParams]` | Inspection-to-inspection delta threshold | Integer | `40` |
| `OfflineVerification` | `[SystemParams]` | Enable offline verification mode | Boolean 0/1 | `0` |
| `KeepFramesPolicy` | `[SystemParams]` | Frame retention policy during offline verification | Integer | `0` |
| `OfflineVer_SaveMode` | `[SystemParams]` | Save mode for offline verification frames | Integer | `0` |
| `OfflineVer_FilterMode` | `[SystemParams]` | Filter mode for offline verification | Integer | `0` |
| `OfflineVer_JpegQFactor` | `[SystemParams]` | JPEG quality factor for offline verification saves | Integer 0–100 | `50` |
| `ScanOverviewImage_Size_px` | `[SystemParams]` | Overview image output size (pixels) | Integer > 0 | `4096` |
| `ScanOverviewImage_JpegQFactor` | `[SystemParams]` | JPEG quality factor for overview image | Integer 0–100 | `50` |
| `LastModifyTime` | `[SystemParams]` | Timestamp of last calibration file modification | String (`YYYY-MM-DD-HH-MM-SS`) | `2023-02-21-09-44-04` |
| `GainPath` | `[SystemParams]` | Filesystem path to the Gain calibration .tif file | Absolute path string | `C:\Bis\data\images\input\Gain-2023-02-21-09-12-14.tif` |
| `OffsetPath` | `[SystemParams]` | Filesystem path to the Offset calibration .tif file | Absolute path string | `C:\Bis\data\images\input\Offset-2023-02-21-09-12-14.tif` |
| `DistortionPath` | `[SystemParams]` | Filesystem path to the Distortion calibration .tif file | Absolute path string | `C:\Bis\data\images\input\Distortion-2023-02-21-09-44-04.tif` |
| `CameraCalibPath` | `[SystemParams]` | Root path to camera calibration data | Absolute path string | `C:\Falcon\data\Machine\MachineName\Cameras\HaighMag` |
| `VectorUncertanty_px` | `[SystemParams]` | Vector alignment uncertainty tolerance (pixels) | Integer > 0 | `500` |
| `IvpPitch` | `[SystemParams]` | IVP (in-line verification) pitch (µm) | Float | `0.220000` |
| `IVP_LineDistortion_PolynomCoef_N` | `[SystemParams]` | Polynomial coefficients 1–10 for IVP line distortion model | Float | `0.000000` |
| `CCS_MechanicalShiftForLow` / `ForHigh` | `[SystemParams]` | CCS mechanical Z shift for low/high scan position (µm) | Float | `0.000000` |
| `CreateRef_FileFormat` | `[SystemParams]` | File format code for created reference images | Integer | `1` |
| `SaveAlgInputData` | `[SystemParams]` | Save algorithm input data for debug | Boolean 0/1 | `1` |
| `AlignStripDelayOverloadFactorPercent` | `[FrameControl]` | Strip alignment delay overload factor (%) | Integer | `100` |

---

## File 23 — `c:\job\<JobName>\<Setup>\Recipes\<R>\Params_WaferInfo.ini`

**Purpose:** Run-time path mirror and scan configuration snapshot — stores resolved filesystem paths for all recipe-related folders and operational scan parameters computed at load time by AOI_Main.

| Parameter Name | Section | Description | Accepted Values / Type | Example Value |
|---|---|---|---|---|
| `SetupPath` | `[Path]` | Resolved filesystem path to the setup folder | Absolute path string | `c:\job\Diced_10.0.4511\S1\Recipes\R1\` |
| `RecipeName` | `[Path]` | Active recipe name | String | `R1` |
| `RecipePath` | `[Path]` | Resolved filesystem path to the recipe folder | Absolute path string | `c:\job\Diced_10.0.4511\S1\Recipes\R1\` |
| `ScanResultsPath` | `[Path]` | Path where scan results are written | Absolute path string | `c:\job\Diced_10.0.4511\S1\Recipes\R1\` |
| `TrainPath` | `[Path]` | Path to the TrainData folder | Absolute path string | `c:\job\Diced_10.0.4511\S1\Recipes\R1\\TrainData\` |
| `ReferenceChange` | `[General]` | Flag indicating the reference was changed since last scan | Boolean 0/1 | `1` |
| `CollectSpcData` | `[General]` | Collect SPC statistics during this scan | Boolean 0/1 | `0` |
| `OverlapX` | `[General]` | Frame overlap in X direction (pixels) | Integer ≥ 0 | `75` |
| `OverlapY` | `[General]` | Frame overlap in Y direction (pixels) | Integer ≥ 0 | `75` |
| `DuplicateRangeX` | `[General]` | Duplicate defect merge range in X (µm) | Integer ≥ 0 | `15` |
| `DuplicateRangeY` | `[General]` | Duplicate defect merge range in Y (µm) | Integer ≥ 0 | `15` |
| `DuplicateRangeX_px` | `[General]` | Duplicate defect merge range in X (pixels) | Integer ≥ 0 | `5` |
| `DuplicateRangeY_px` | `[General]` | Duplicate defect merge range in Y (pixels) | Integer ≥ 0 | `5` |
| `SearchRangeX` | `[General]` | Pattern search range in X (pixels) | Integer ≥ 0 | `5` |
| `SearchRangeY` | `[General]` | Pattern search range in Y (pixels) | Integer ≥ 0 | `5` |
| `AlignStripDelay` | `[General]` | Alignment strip delay value (-1=auto) | Integer | `-1` |
| `RefPixelSizeX` | `[General]` | Reference pixel size in X (µm) | Float > 0 | `0.8576509` |
| `RefPixelSizeY` | `[General]` | Reference pixel size in Y (µm) | Float > 0 | `0.8576509` |
| `BinArrayPath` | `[General]` | Path to binary array data directory | Absolute path string | `c:\bis\data\dds` |
| `DieSize_X` | `[Geometry]` | Die size in X (µm) | Float > 0 | `3530.588400` |
| `DieSize_Y` | `[Geometry]` | Die size in Y (µm) | Float > 0 | `16848.215000` |
| `DieStep_X` | `[Geometry]` | Die pitch/step in X (µm) | Float > 0 | `3613.400000` |
| `DieStep_Y` | `[Geometry]` | Die pitch/step in Y (µm) | Float > 0 | `16933.000000` |
| `Diameter` | `[Geometric]` | Wafer diameter (µm) | Float > 0 | `200000.000000` |
| `EBR` | `[Geometric]` | Edge bead removal width (µm) | Float ≥ 0 | `0.000000` |
| `FlatNotchVal` | `[Geometric]` | Flat/notch value (-1=none) | Float | `-1.000000` |
| `WaferBuildType` | `[WaferParam]` | Wafer build type code | Integer | `2` |
| `IsSingleDieReference` | `[WaferParam]` | Whether a single die is used as reference | Boolean 0/1 | `0` |
| `IsSingleDieRasterReference` | `[WaferParam]` | Whether single die raster reference is used | Boolean 0/1 | `1` |
| `ScanPartialDice` | `[Scan]` | Include partial (edge) dice in scan | Boolean 0/1 | `0` |
| `ScanStreets` | `[Scan]` | Scan street regions between dice | Boolean 0/1 | `0` |
| `ScanByScanAreas` | `[Scan]` | Use scan area definitions instead of full die grid | Boolean 0/1 | `0` |
| `ScanTNERegion` | `[Scan]` | Scan the TNE (Test-Not-Etch) region | Boolean 0/1 | `0` |
| `ScanEBRMask` | `[Scan]` | Apply EBR mask during scan | Boolean 0/1 | `0` |

---

## File 24 — `c:\job\<JobName>\<Setup>\Recipes\<R>\RTP.txt`

**Purpose:** Human-readable plain-text specification of per-zone algorithm parameters (RTP values), organized by zone name and algorithm name with inline comments. Serves as the source definition from which zone `.ini` files are generated; written at recipe creation.

| Parameter Name | Zone / Algorithm | Description | Accepted Values / Type | Example Value |
|---|---|---|---|---|
| `Inner_Radius_[Microns]` | PostProcess / Warp_Direction_Calculation | Inner circle radius for warp calculation (µm) | Float > 0 | `1` |
| `Outer_Radius_[Microns]` | PostProcess / Warp_Direction_Calculation | Outer circle radius for warp calculation (µm) | Float > Inner_Radius | `2` |
| `Shape_Violation_USL` | PostProcess / Volume | Maximum allowed bump volume | Float > 0 | `90000` |
| `Shape_Violation_LSL` | PostProcess / Volume | Minimum allowed bump volume | Float ≥ 0 | `9000` |
| `Coplanarity_USL` | PostProcess / Coplanarity | Maximum allowed coplanarity (µm) | Float > 0 | `50` |
| `Coplanarity_Method` | PostProcess / Coplanarity | Coplanarity method (1=P2P, 2=P2Avg, 3=Seated, 4=Global, 5=Neighbor) | Integer 1–5 | `1` |
| `LSL_Bump_Height_Average` | PostProcess / Coplanarity | LSL for average bump height per die (µm) | Float | `0` |
| `USL_Bump_Height_Average` | PostProcess / Coplanarity | USL for average bump height per die (µm) | Float | `500` |
| `Max_Distance_Above_Plane` | PostProcess / Zone_Coplanarity_Params | Max distance above reference plane for zone coplanarity | Float | `0` |
| `Max_Distance_Below_Plane` | PostProcess / Zone_Coplanarity_Params | Max distance below reference plane (µm) | Float | `35` |
| `Neighbor_Dir` | PostProcess / Zone_Coplanarity_Params | Neighbor direction (0=Both, 1=Horizontal, 2=Vertical) | Integer 0–2 | `0` |
| `Correlation_range` | PostProcess / Height_Post_Process | Tolerance range for height correlation | Float 0.0–1.0 | `0.15` |
| `max_dX_[Micron]` | PostProcess / Target_Measurement | Max X deviation for target measurement (µm) (-1=disabled) | Float | `-1` |
| `max_dY_[Micron]` | PostProcess / Target_Measurement | Max Y deviation for target measurement (µm) (-1=disabled) | Float | `-1` |
| `max_allowed_defects` | PostProcess / Target_Measurement | Maximum allowed target defects | Integer ≥ 0 | `0` |
| `Max_Diff_In_Percent` | PostProcess / SB_Die_Level | Max bump radius delta from average (%) | Float > 0 | `100` |
| `Max_Diff_In_Microns` | PostProcess / SB_Die_Level | Max bump radius delta from average (µm) | Float > 0 | `100` |
| `STDV_of_Average` | PostProcess / SB_Die_Level | Max allowed standard deviation of bump radius | Float > 0 | `100` |
| `Min_Defect_Area_-_Bright` | Scan_Area / Surface | Minimum bright defect area (µm²) | Float > 0 | `100.04` |
| `Min_Defect_Width_-_Bright` | Scan_Area / Surface | Minimum bright defect width (µm) | Float > 0 | `35` |
| `Min_Defect_Length_-_Bright` | Scan_Area / Surface | Minimum bright defect length (µm) | Float > 0 | `49.74` |
| `Contrast_Delta_-_Bright` | Scan_Area / Surface | Minimum bright defect contrast above max reference | Integer > 0 | `30` |
| `Min_Defect_Area_-_Dark` | Scan_Area / Surface | Minimum dark defect area (µm²) | Float > 0 | `100.04` |
| `Min_Defect_Width_-_Dark` | Scan_Area / Surface | Minimum dark defect width (µm) | Float > 0 | `35` |
| `Min_Defect_Length_-_Dark` | Scan_Area / Surface | Minimum dark defect length (µm) | Float > 0 | `49.74` |
| `Contrast_Delta_-_Dark` | Scan_Area / Surface | Minimum dark defect contrast below min reference | Integer > 0 | `12` |
| `Bright_Uncertainty` | Scan_Area / Surface | Edge uncertainty reduction for bright edges | Float ≥ 0 | `0` |
| `Dark_Uncertainty` | Scan_Area / Surface | Edge uncertainty reduction for dark edges | Float ≥ 0 | `0` |
| `Elongation` | Scan_Area / Surface | Minimum elongation (length/width) filter (-1=disabled) | Float | `-1` |

---

## File 25 — `c:\job\<JobName>\<Setup>\Recipes\<R>\OpticPreset.ini`

**Purpose:** Stores the optical and illumination preset for the recipe — camera scenario GUID, focus position above chuck, magnification, and whether an illumination-conversion pass has been executed. Updated by DataServer/RMS on recipe load.

| Parameter Name | Section | Description | Accepted Values / Type | Example Value |
|---|---|---|---|---|
| `Executed` | `[IllumConversion]` | Whether illumination conversion has been executed for this preset | Boolean 0/1 | `0` |
| `Signature` | `[General]` | Preset format signature version | Integer | `1` |
| `Id` | `[Scan2d]` | GUID of the Scan2d scenario this preset belongs to | UUID string | `d5ecdfdf-532b-4995-96f7-3d14b6fa5c0c` |
| `FocusPosAboveChuck` | `[Scan2d]` | Optimal focus Z position above chuck surface (µm) | Float | `368.348585003619` |
| `Mag` | `[Scan2d]` | Optical magnification factor | Integer | `5` |
| `Mode` | `[Scan2d]` | Illumination mode code (-1=auto) | Integer | `-1` |
| `CameraName` | `[Scan2d]` | Camera identifier string | String | `HighMag` |

---

## File 26 — `c:\job\<JobName>\<Setup>\Recipes\<R>\JobIllumLimits.ini`

**Purpose:** Stores the illumination calibration date and an optional forced-skip expiry date for the job's illumination-limits check. DataServer uses this to decide whether to validate illumination before accepting a scan.

| Parameter Name | Section | Description | Accepted Values / Type | Example Value |
|---|---|---|---|---|
| `IllumCalibDate` | `[AMITA1]` | Date and time of the last illumination calibration | ISO datetime string (`YYYY-MM-DD HH:MM:SS`) | `2026-02-22 11:26:28` |
| `ForcedSkipToDate` | `[AMITA1]` | Date until which the illumination limit check is forcibly skipped | ISO datetime string | `2026-04-14 14:36:35` |

---

## File 27 — `c:\job\<JobName>\<Setup>\Recipes\<R>\OpticToVCamStorage.json`

**Purpose:** JSON array mapping each optical preset GUID to the virtual camera (VCam) storage GUID for each named scenario. Links Scan, CleanReference, and Alignment scenarios to their corresponding image storage location. Written at recipe creation; updated by AOI_Main when scenarios change.

| Parameter Name | Type | Description | Accepted Values / Type | Example Value |
|---|---|---|---|---|
| `OpticId` | per entry | GUID of the optical preset | UUID string | `fa520c77-45ae-48dd-afff-47b8caf409a6` |
| `Scenario` | per entry | Scenario name this mapping applies to | String enum: `Scan`, `CleanReference`, `Alignment` | `Scan` |
| `IsAutoFocus` | per entry | Whether autofocus is used in this scenario | Boolean | `false` |
| `StorageId` | per entry | GUID of the VCam storage location for this scenario | UUID string | `109bf039-3af0-49e9-9d6c-cf890bf591ef` |

---

## File 28 — `c:\job\<JobName>\<Setup>\Recipes\<R>\ZoomLevels.ini`

**Purpose:** Defines the multi-resolution zoom pyramid for the recipe's reference images — which zoom levels are generated, whether they are compressed, their pixel dimensions, and the die pitch used to compute them. Written at recipe creation.

| Parameter Name | Section | Description | Accepted Values / Type | Example Value |
|---|---|---|---|---|
| `LEVEL_1` | `[ZOOM_LEVELS]` | Generate 1x (full-resolution) zoom level | Boolean 0/1 | `1` |
| `LEVEL_2` | `[ZOOM_LEVELS]` | Generate 2x zoom level | Boolean 0/1 | `1` |
| `LEVEL_4` | `[ZOOM_LEVELS]` | Generate 4x zoom level | Boolean 0/1 | `1` |
| `LEVEL_8` | `[ZOOM_LEVELS]` | Generate 8x zoom level | Boolean 0/1 | `1` |
| `LEVEL_16` | `[ZOOM_LEVELS]` | Generate 16x zoom level | Boolean 0/1 | `1` |
| `LEVEL_32` | `[ZOOM_LEVELS]` | Generate 32x zoom level | Boolean 0/1 | `1` |
| `SaveCompressed` | `[ZOOM_LEVELS]` | Save reference levels as compressed images | Boolean 0/1 | `0` |
| `SizeX` | `[LEVEL_N]` | Image width in pixels at zoom level N | Integer > 0 | `4116` (at 1x) |
| `SizeY` | `[LEVEL_N]` | Image height in pixels at zoom level N | Integer > 0 | `19644` (at 1x) |
| `Step_X` | `[DIE]` | Die step in X (µm) used to build zoom pyramid | Float > 0 | `4213.1361` |
| `Step_Y` | `[DIE]` | Die step in Y (µm) used to build zoom pyramid | Float > 0 | `19743.4640` |

---

## File 29 — `c:\job\<JobName>\<Setup>\Recipes\<R>\zones.ini`

**Purpose:** Defines the zone configuration for a recipe — zone IDs, algorithm names, bin codes, display colors, mask-ignore flags, and per-zone mask pixel counts. Written at recipe creation by RMS.

| Parameter Name | Section | Description | Accepted Values / Type | Example Value |
|---|---|---|---|---|
| `Version` | `[General]` | File format version | Integer | `11` |
| `<ZoneID>` | `[ALGName]` | Human-readable name of zone with this ID | String | `255` → `PostProcess`, `0` → `Scan Area` |
| `<ZoneID>` | `[ALG]` | Algorithm assigned to zone | String | `255` → `PostProcess`, `0` → `Surface` |
| `<ZoneID>` | `[BinCodes]` | Bin code for defects in this zone (-1=default) | Integer | `-1` |
| `<ZoneID>` | `[Color Name]` | Display color for zone in UI (hex) | `#RRGGBB` string | `#FFFFFF` |
| `<ZoneID>` | `[IgnoreMsk]` | Ignore mask pixels in this zone | Boolean 0/1 | `0` |
| `<ZoneID>` | `[IgnoreOverlap]` | Ignore frame overlap in this zone | Boolean 0/1 | `0` |
| `Groups` | `[MultiProject]` | Multi-project group assignments | String (may be empty) | *(empty)* |
| `<ZoneID>` | `[MskPixelCount]` | Count of mask pixels in this zone | Integer ≥ 0 | `80854704` |

---

## File 30 — `c:\job\<JobName>\<Setup>\Recipes\<R>\zones.txt`

**Purpose:** Human-readable spatial definition of recipe zones — scale factors and per-zone reference center position, shape type, dimensions (width × height), and offset in pixel coordinates. Written at recipe creation as companion to `zones.ini`.

| Parameter Name | Description | Accepted Values / Type | Example Value |
|---|---|---|---|
| `ScaleX` | X scale factor applied to all zone coordinates | Float | `1.0000000000` |
| `ScaleY` | Y scale factor applied to all zone coordinates | Float | `1.0000000000` |
| `RefID` | Sequential reference ID for this zone entry | Integer ≥ 1 | `1` |
| `X` | Zone center X position (pixels) | Float | `2058.0` |
| `Y` | Zone center Y position (pixels) | Float | `9822.0` |
| `Zone` | Zone ID this entry belongs to | Integer | `0` |
| `Count` | Number of shape vertices (0=rectangle) | Integer | `0` |
| Shape Data (width) | Width of the zone shape (pixels) | Integer > 0 | `4116` |
| Shape Data (height) | Height of the zone shape (pixels) | Integer > 0 | `19644` |
| Shape Data (offset) | Shape offset value | Integer | `0` |

---

## File 31 — `c:\job\<JobName>\<Setup>\Recipes\<R>\DieMapRegPos.txt`

**Purpose:** Text listing of die-map registration position ROIs — four 64×64 pixel reference patches at die corners used by the die-mapping algorithm to register the die in the scan. Same spatial format as `zones.txt`.

| Parameter Name | Description | Accepted Values / Type | Example Value |
|---|---|---|---|
| `ScaleX` / `ScaleY` | Scale factors for coordinates | Float | `1.0` |
| `RefID` | Sequential reference ID | Integer ≥ 1 | `1` |
| `X` / `Y` | Center position of registration ROI (pixels) | Float | `116.0` / `385.0` |
| `Zone` | Zone ID | Integer | `0` |
| Shape Data (width × height) | Registration ROI dimensions (pixels) | Integer | `64 × 64` |

---

## File 32 — `c:\job\<JobName>\<Setup>\Recipes\<R>\DieRegPos.txt`

**Purpose:** Text listing of die registration position ROIs — four 64×64 corner patches used for fine die registration (slightly different positions from `DieMapRegPos.txt`). Same spatial format as File 31.

| Parameter Name | Description | Accepted Values / Type | Example Value |
|---|---|---|---|
| *(same structure as File 31 — DieMapRegPos.txt)* | | | |
| `X` / `Y` | Center position of corner patch (pixels) — values differ from DieMapRegPos | Float | `112.0` / `181.0` (corner 1) |

---

## File 33 — `c:\job\<JobName>\<Setup>\Recipes\<R>\Zones\<zone>.ini`

**Purpose:** Per-zone algorithm configuration file storing all inspection algorithms assigned to a zone and their complete RTP parameter sets. One file per zone name (e.g., `PostProcess.ini`, `Scan_Area.ini`). Written at recipe creation.

| Parameter Name | Section | Description | Accepted Values / Type | Example Value |
|---|---|---|---|---|
| `ZoneName` | `[General]` | Human-readable zone name | String | `PostProcess` |
| `ZoneID` | `[General]` | Numeric zone identifier | Integer | `255` |
| `TypeName` | `[General]` | Zone type classifier | String | `PostProcess` |
| `AutoTH` | `[General]` | Enable auto-threshold for this zone | Boolean 0/1 | `0` |
| `AutoProbe` | `[General]` | Enable auto-probe for this zone | Boolean 0/1 | `0` |
| `Enable` | `[<AlgorithmName>]` | Whether this algorithm is active in the zone | Boolean 0/1 | `0` |
| `AlgorithmName` | `[<AlgorithmName>]` | Algorithm identifier string | String | `Coplanarity` |
| `Classify` | `[<AlgorithmName>]` | Classification code for defects found by this algorithm | Integer | `-1` |
| `RegionId` | `[<AlgorithmName>]` | Region ID this algorithm applies to | Integer | `0` |
| `USL_Volume` | `[Volume]` | Upper spec limit for bump volume | Float > 0 | `90000.000000` |
| `LSL_Volume` | `[Volume]` | Lower spec limit for bump volume | Float ≥ 0 | `9000.000000` |
| `CoplanarityMax` | `[Coplanarity]` | Maximum coplanarity value (µm) | Float > 0 | `50.000000` |
| `CoplanarityProc` | `[Coplanarity]` | Coplanarity calculation method | Integer 1–5 | `1` |
| `AverageUSL` | `[Coplanarity]` | USL for average bump height per die (µm) | Float | `500.000000` |
| `PlaneId` | `[Coplanarity]` | Coplanarity plane identifier | Integer | `0` |
| `MaxDistAbovePlane` / `MaxDistBelowPlane` | `[ZoneCoplanarity]` | Max allowed distance above/below reference plane (µm) | Float | `0.0` / `35.0` |
| `MaxDeltaMic` | `[SBDieLevel]` | Max bump radius delta from average (µm) | Float | `100.000000` |
| `MaxDeltaPercent` | `[SBDieLevel]` | Max bump radius delta from average (%) | Float | `100.000000` |
| `ContributeToGlobalAdaptiveHistogram` | `[ZoneRTP]` | Include this zone in global adaptive histogram | Boolean 0/1 | `0` |
| `IgnoreMsksAndOverlap` | `[ZoneRTP]` | Ignore both masks and overlap in this zone | Boolean 0/1 | `0` |
| `IgnoreOverlap` | `[ZoneRTP]` | Ignore frame overlap in this zone | Boolean 0/1 | `0` |
| `IgnoreMsk` | `[ZoneRTP]` | Ignore mask pixels in this zone | Boolean 0/1 | `0` |

---

## File 34 — `c:\job\<JobName>\<Setup>\Recipes\<R>\ScenariosMetadatas.ini`

**Purpose:** Metadata registry linking each named scan scenario to its optic preset GUID and reference scenario GUID. Written at recipe creation; updated when scenarios are added or reconfigured.

| Parameter Name | Section | Description | Accepted Values / Type | Example Value |
|---|---|---|---|---|
| `Version` | `[General]` | File format version | Integer | `1` |
| `Id` | `[<ScenarioName>]` | Unique GUID for this scenario instance | UUID string | `d65783d2-b589-4005-a387-47cd3b398afa` |
| `OpticsId` | `[<ScenarioName>]` | GUID of the associated optics preset | UUID string | `fa520c77-45ae-48dd-afff-47b8caf409a6` |
| `ReferenceScenario` | `[<ScenarioName>]` | GUID of the reference scenario for comparison | UUID string | `fa520c77-45ae-48dd-afff-47b8caf409a6` |

---

## File 35 — `c:\job\<JobName>\<Setup>\Recipes\<R>\CcsLocalMeas.ini`

**Purpose:** Configures local CCS (height measurement) revisit scan parameters — margins, step sizes, and dynamic vs. static method flags used when re-scanning specific defect locations at higher resolution.

| Parameter Name | Section | Description | Accepted Values / Type | Example Value |
|---|---|---|---|---|
| `MarginX` | `[ScanParams]` | Scan margin added in X direction (µm) | Integer ≥ 0 | `0` |
| `MarginY` | `[ScanParams]` | Scan margin added in Y direction (µm) | Integer ≥ 0 | `0` |
| `ScanStepX` | `[ScanParams]` | Scan step size in X (µm) | Integer ≥ 0 | `0` |
| `ScanStepY` | `[ScanParams]` | Scan step size in Y (µm) | Integer ≥ 0 | `0` |
| `ResultsToRevisit` | `[ScanParams]` | Comma-separated list of result IDs to revisit | String (may be empty) | *(empty)* |
| `ScanDefects_Enabled` | `[ScanParams]` | Enable defect re-scanning | Boolean 0/1 | `0` |
| `ScanDefects_SizeX` | `[ScanParams]` | Defect re-scan region width (µm) | Integer ≥ 0 | `0` |
| `ScanDefects_SizeY` | `[ScanParams]` | Defect re-scan region height (µm) | Integer ≥ 0 | `0` |
| `NoiseReduction` | `[ScanParams]` | Apply noise reduction to revisit scans | Boolean 0/1 | `0` |
| `IsDynamicMethod` | `[ScanParams]` | Use dynamic CCS measurement method | Boolean 0/1 | `0` |
| `Version` | `[General]` | File format version | Float | `0.0000` |

---

## File 36 — `c:\job\<JobName>\<Setup>\Recipes\<R>\CleanReferenceConfiguration.ini`

**Purpose:** Controls when and how clean reference images are created — periodicity, comparison validation behavior, and image quality parameters for detecting a bad clean reference before accepting it.

| Parameter Name | Section | Description | Accepted Values / Type | Example Value |
|---|---|---|---|---|
| `Version` | `[General]` | File format version | Integer | `1` |
| `CreateCleanReferencePeriodicaly` | `[General]` | Enable periodic clean reference creation | Boolean 0/1 | `1` |
| `CreateCleanReferenceEvery` | `[General]` | Period trigger: `Wafer`, `Lot`, or integer N | String/Integer | `Wafer` |
| `CreateCleanReferenceFrequency` | `[General]` | Create every N wafers (0=every) | Integer ≥ 0 | `0` |
| `IsCleanDuringScan` | `[General]` | Perform clean reference creation during active scan | Boolean 0/1 | `0` |
| `IsEnableForManualScan` | `[General]` | Enable clean reference in manual scan mode | Boolean 0/1 | `0` |
| `IsEnableExcludeCleanFromJob` | `[General]` | Allow excluding clean wafer from job results | Boolean 0/1 | `0` |
| `CleanReferenceCounter` | `[General]` | Internal wafer counter since last clean reference | Integer ≥ 0 | `0` |
| `ComparisonRequired` | `[Behevior]` | Require comparison validation of clean reference | Boolean 0/1 | `0` |
| `OnComparisonMismatch` | `[Behevior]` | Action when comparison fails | String enum (`GenerateError`, `Continue`, …) | `GenerateError` |
| `OnComparionSuccessful` | `[Behevior]` | Action code when comparison succeeds | Integer | `0` |
| `MaximumContrast` | `[ComparisonParameters]` | Max allowed contrast difference in comparison | Integer | `10` |
| `MaximumSensitivity` | `[ComparisonParameters]` | Max allowed sensitivity difference | Float | `0.5` |
| `CompareMethod` | `[ComparisonParameters]` | Comparison method code | Integer | `0` |
| `NumberOpening` | `[ComparisonParameters]` | Number of morphological opening iterations | Integer ≥ 0 | `1` |
| `NumberClosing` | `[ComparisonParameters]` | Number of morphological closing iterations | Integer ≥ 0 | `0` |
| `SaveDebug` | `[ComparisonParameters]` | Save debug images during comparison | Boolean 0/1 | `0` |
| `ComparisonThreadsNumber` | `[ComparisonParameters]` | Number of threads for comparison | Integer ≥ 1 | `1` |
| `BadPixelsThreshold` | `[ComparisonParameters]` | Maximum bad pixels allowed before rejecting reference | Integer ≥ 0 | `10000` |
| `BadDieForCleanBehavior` | `[ComparisonParameters]` | Strategy when a die is bad for clean reference | String enum | `UseClosestGoodNeighborDie` |

---

## File 37 — `c:\job\<JobName>\<Setup>\Recipes\<R>\CleanReferenceFinalParams.ini`

**Purpose:** Stores the computed parameters used to build the final clean reference image — frame size, quality threshold criteria, re-alignment settings, and memory quotas for the clean reference creation pipeline.

| Parameter Name | Section | Description | Accepted Values / Type | Example Value |
|---|---|---|---|---|
| `Version` | `[General]` | File format version | Integer | `2` |
| `SizeX` | `[CleanRefParams]` | Frame width for clean reference (pixels) | Integer > 0 | `1280` |
| `SizeY` | `[CleanRefParams]` | Frame height for clean reference (pixels) | Integer > 0 | `1280` |
| `minCriteria` | `[CleanRefParams]` | Minimum quality criteria multiplier | Integer | `-2` |
| `maxCriteria` | `[CleanRefParams]` | Maximum quality criteria multiplier | Integer | `-1` |
| `minCreateMul` | `[CleanRefParams]` | Minimum create multiplier | Integer | `2` |
| `maxCreateMul` | `[CleanRefParams]` | Maximum create multiplier | Integer | `2` |
| `NumScannedDice` | `[CleanRefParams]` | Number of dice scanned to build the reference | Integer ≥ 1 | `11` |
| `CreateGl` | `[CleanRefParams]` | Create gray-level reference | Boolean 0/1 | `1` |
| `CreateMin` | `[CleanRefParams]` | Create minimum reference channel | Boolean 0/1 | `1` |
| `CreateMax` | `[CleanRefParams]` | Create maximum reference channel | Boolean 0/1 | `1` |
| `MaxIterations` | `[ReAlignFrames]` | Maximum frame re-alignment iterations | Integer ≥ 1 | `5` |
| `MSEImprovementPercent` | `[ReAlignFrames]` | Minimum MSE improvement to accept re-alignment (%) | Float | `1` |
| `Enable` | `[ReAlignFrames]` | Enable frame re-alignment during reference build | Boolean 0/1 | `1` |
| `BlockSize` | `[ReAlignFrames]` | Block size for re-alignment scoring (pixels) | Integer > 0 | `128` |
| `BlockMinScore` | `[ReAlignFrames]` | Minimum block score to accept re-alignment | Integer 0–100 | `85` |
| `FastCleanReference` | `[Scenario]` | Fast clean reference mode (0=off, 1=fast, 2=faster) | Integer 0–2 | `2` |
| `MemoryQuotaForDieImagesMb` | `[Scenario]` | Memory quota for die images during build (MB) | Integer > 0 | `200` |
| `MemoryQuotaForReferenceComparisonMb` | `[Scenario]` | Memory quota for reference comparison (MB) | Integer > 0 | `500` |
| `PerformCleanOnPizza` | `[Scenario]` | Use pizza wafer for clean reference | Boolean 0/1 | `0` |
| `UseCleanReferenceFolder` | `[Scenario]` | Use dedicated clean reference folder | Boolean 0/1 | `0` |

---

## File 38 — `c:\job\<JobName>\<Setup>\Recipes\<R>\CreateReference3dOptions.ini`

**Purpose:** Parameters for 3D (height-map) reference image creation — registration method, stitching policy, segmentation block sizes, scan overlap, and cleaning method. Written at recipe creation.

| Parameter Name | Section | Description | Accepted Values / Type | Example Value |
|---|---|---|---|---|
| `Version` | `[General]` | File format version | Integer | `0` |
| `Debug` | `[General]` | Enable debug output during 3D reference creation | Boolean 0/1 | `0` |
| `ReferenceRegBy` | `[Registration]` | Registration method code | Integer | `0` |
| `BigBlockRowsNumber` | `[Registration]` | Number of rows per registration block | Integer > 0 | `1000` |
| `YPartitionsNumber` | `[Registration]` | Number of Y partitions for registration | Integer ≥ 1 | `3` |
| `MaxErrorPix` | `[Registration]` | Maximum registration error (pixels) | Integer > 0 | `3` |
| `PScoreTH` | `[Registration]` | P-score threshold for registration acceptance | Integer 0–100 | `20` |
| `QScoreTH` | `[Registration]` | Q-score threshold | Integer 0–100 | `20` |
| `StitchingPolicy` | `[Stitching]` | Stitching method (0=none, 1=linear blend, …) | Integer | `1` |
| `OrthoPolicy` | `[Stitching]` | Orthogonal stitching policy | Integer | `0` |
| `InterpulationPolicy` | `[Stitching]` | Interpolation policy | Integer | `1` |
| `DetrendPolicy` | `[Stitching]` | Detrend policy | Integer | `1` |
| `SegmentorBlockSize` | `[Segmentation]` | Segmentation block size (pixels) | Integer > 0 | `4000` |
| `SegmentorBlockOverlapPercentage` | `[Segmentation]` | Block overlap as fraction of block size | Float 0.0–1.0 | `0.25` |
| `SegmentorLayerThickness` | `[Segmentation]` | Layer thickness for 3D segmentation | Integer > 0 | `11` |
| `CleanMethod` | `[Clean]` | Cleaning method code for 3D reference | Integer | `5` |
| `ScanTrueOverlapXpix` | `[Scan]` | True scan overlap in X (pixels) | Integer ≥ 0 | `200` |
| `FalseGap` | `[Scan]` | False gap between scan strips (pixels) | Integer ≥ 0 | `0` |

---

## File 39 — `c:\job\<JobName>\<Setup>\Recipes\<R>\OverlayScan.ini`

**Purpose:** Minimal configuration linking the recipe to an overlay scan scenario definition via a unique GUID. Written at recipe creation.

| Parameter Name | Section | Description | Accepted Values / Type | Example Value |
|---|---|---|---|---|
| `Id` | `[General]` | GUID of the overlay scan scenario | UUID string | `e915d5d2-e7f7-4891-3703-00aab9ba53f4` |

---

## File 40 — `c:\job\<JobName>\<Setup>\Recipes\<R>\SamplingMetrology.ini`

**Purpose:** Minimal configuration for sampling metrology — a unique scenario ID and whether CSV-based position input is used instead of automatic site selection.

| Parameter Name | Section | Description | Accepted Values / Type | Example Value |
|---|---|---|---|---|
| `Version` | `[General]` | File format version | Integer | `0` |
| `Id` | `[General]` | Sampling metrology scenario GUID | UUID string | `c26d8ada-247a-dc13-4998-f6563a2eea4b` |
| `UseCSV` | `[General]` | Use CSV file for sampling site positions | Boolean 0/1 | `0` |

---

## File 41 — `c:\job\<JobName>\<Setup>\Recipes\<R>\UniqueArea.ini`

**Purpose:** Configures unique-area (unique-pattern) alignment — number of defined areas, GMF usage, minimum match score, and the image pre-processor engine applied before matching.

| Parameter Name | Section | Description | Accepted Values / Type | Example Value |
|---|---|---|---|---|
| `Count` | `[General]` | Number of unique areas defined | Integer ≥ 0 | `0` |
| `UseGMF` | `[General]` | Use GMF engine for unique area matching | Boolean 0/1 | `0` |
| `TryAllModels` | `[General]` | Try all candidate models before failing | Boolean 0/1 | `0` |
| `MinTargetScore` | `[General]` | Minimum match score required | Integer 0–100 | `0` |
| `ImagePreprocessorId` | `[General]` | UUID of selected image pre-processor engine | UUID string | `306a7e84-3bae-4443-bedf-ea9321f61841` |
| `<UUID>_EngineID` | `[<UUID>]` | Engine self-reference ID | UUID string | `306a7e84-…` |
| `<UUID>_EngineDescription` | `[<UUID>]` | Engine description string | String | `No Operation` |
| `<UUID>_EngineIsControlable` | `[<UUID>]` | Whether engine exposes user-controllable parameters | Boolean 0/1 | `0` |

---

## File 42 — `c:\job\<JobName>\<Setup>\Recipes\<R>\ExternalCoordSystems.ini`

**Purpose:** Registry of external coordinate systems for result export to third-party metrology tools. No systems are defined in any observed recipe — file contains only a count of zero.

| Parameter Name | Section | Description | Accepted Values / Type | Example Value |
|---|---|---|---|---|
| `Count` | `[ExternalCoordSystems]` | Number of external coordinate systems defined | Integer ≥ 0 | `0` |

---

## File 43 — `c:\job\<JobName>\<Setup>\Recipes\<R>\Metadata.ini` *(recipe level)*

**Purpose:** Recipe-level identity file storing name, unique GUID, and version counter. Minimal traceability record written by RMS at recipe creation.

| Parameter Name | Section | Description | Accepted Values / Type | Example Value |
|---|---|---|---|---|
| `name` | `[General]` | Recipe name | String | `R1` |
| `Id` | `[General]` | Recipe unique GUID | UUID string | `ecd7a3d7-87c8-4b99-ad53-6a0ff08506be` |
| `Version` | `[General]` | Recipe schema version counter | Integer | `0` |

---

## File 44 — `c:\job\<JobName>\<Setup>\Recipes\<R>\WaferDataReadSettings.xml`

**Purpose:** XML configuration defining data-read sessions executed when loading wafer data into the recipe. In all observed instances the session list is empty, indicating no external data reads are configured.

| Parameter Name | XML Path | Description | Accepted Values / Type | Example Value |
|---|---|---|---|---|
| `DataReadSessions` | `<WaferDataReadSettings>/<DataReadSessions>` | List of data-read session elements; each session would define source, format, and target mapping | XML element (empty list observed) | *(empty)* |

---

## File 45 — `c:\job\<JobName>\<Setup>\Recipes\<R>\WaferMapRecipe.ini`

**Purpose:** Controls wafer map import and update behavior at recipe scope — whether external maps are imported, fiducial alignment, import and update directories, matching policy, and validation flags.

| Parameter Name | Section | Description | Accepted Values / Type | Example Value |
|---|---|---|---|---|
| `SettingsPolicy` | `[GENERAL]` | Map settings inheritance policy | Integer | `0` |
| `FiducialBin` | `[GENERAL]` | Bin code for fiducial markers (-1=none) | Integer | `-1` |
| `MappingCorner` | `[GENERAL]` | Reference corner for map orientation alignment | Integer | `0` |
| `Enable` | `[Input_Update]` | Enable map import/update for this recipe | Boolean 0/1 | `0` |
| `FileMask` | `[Input_Update]` | Filename wildcard for map files to import | String (may be empty) | *(empty)* |
| `ImportDirectory` | `[Input_Update]` | Directory path for incoming map files | Absolute path string (may be empty) | *(empty)* |
| `UpdateDirectory` | `[Input_Update]` | Directory path where updated maps are written | Absolute path string (may be empty) | *(empty)* |
| `AutoMatchEveryWafer` | `[Input_Update]` | Automatically match wafer map on every wafer | Boolean 0/1 | `0` |
| `ImportUpdateFalconReferenceDie.Col` | `[Input_Update]` | Die column used as reference for import alignment (-1=auto) | Integer | `-1` |
| `ImportUpdateFalconReferenceDie.Row` | `[Input_Update]` | Die row used as reference for import alignment (-1=auto) | Integer | `-1` |
| `FiducialStep.col` / `.row` | `[Input_Update]` | Fiducial step in die-grid units | Integer | `0` |
| `UseMapForScanOnly` | `[Input_Update]` | Use imported map only for defining scan coverage | Boolean 0/1 | `0` |
| `CopyMapToScanResult` | `[Input_Update]` | Copy the imported map into the scan result folder | Boolean 0/1 | `0` |
| `CustPoint1.col` / `.row` | `[Input_Update]` | Customer point 1 die-grid coordinates for alignment | Integer | `0` |
| `CustPoint2.col` / `.row` | `[Input_Update]` | Customer point 2 die-grid coordinates | Integer | `0` |
| `RefPoint1.col` / `.row` | `[Input_Update]` | Falcon reference point 1 die-grid coordinates | Integer | `0` |
| `RefPoint2.col` / `.row` | `[Input_Update]` | Falcon reference point 2 die-grid coordinates | Integer | `0` |
| `Mirror` | `[Input_Update]` | Mirror the imported map | Boolean 0/1 | `0` |
| `PendingUpdateStatus` | `[Input_Update]` | Status code for pending map update (100=SystemDefault) | Integer | `100` |
| `PostScanMapMatchStatus` | `[Input_Update]` | Status code for post-scan map match result | Integer | `100` |
| `RunningMode` | `[Input_Update]` | Map running mode | String (`Normal`, …) | `Normal` |
| `UpdateMapPolicy` | `[Input_Update]` | Map update policy | String (`Default`, …) | `Default` |
| `ScanBinList` | `[Input_Update]` | Comma-separated bin codes treated as scan | String (may be empty) | *(empty)* |
| `EbrBinList` | `[Input_Update]` | Comma-separated bin codes for EBR | String (may be empty) | *(empty)* |
| `ImportFlippedMap` | `[Input_Update]` | Import a vertically flipped map | Boolean 0/1 | `0` |
| `CheckColumnRowCount` | `[Input_Update]` | Validate column/row count against recipe | Boolean 0/1 | `0` |
| `CheckDicePosition` | `[Input_Update]` | Validate die positions in imported map | Boolean 0/1 | `0` |
| `SeparatedImportInMultiRecipe` | `[Input_Update]` | Use separate map import per recipe in multi-recipe setup | Boolean 0/1 | `0` |

---

## File 46 — `c:\job\<JobName>\<Setup>\Recipes\<R>\WaferToRefWafer.ini`

**Purpose:** Stores the affine transform mapping from the current run-wafer coordinate system to the reference wafer coordinate system. Used to report defect positions relative to the reference wafer with sub-pixel accuracy.

| Parameter Name | Section | Description | Accepted Values / Type | Example Value |
|---|---|---|---|---|
| `RW_2_SW_X` | `[WaferToRefWafer]` | X-row of the 2×3 affine matrix (run-wafer → reference-wafer) | Three space-separated floats (R11, R12, Tx) | `0.9998949287  0.0125340258  -215069.5092486806` |
| `RW_2_SW_Y` | `[WaferToRefWafer]` | Y-row of the 2×3 affine matrix | Three space-separated floats (R21, R22, Ty) | `-0.0128299330  0.9999506981  -250385.6822018720` |

---

## File 47 — `c:\job\<JobName>\<Setup>\Recipes\<R>\DieAlignment.dat_block.ini` *(recipe level)*

**Purpose:** Recipe-level die block layout definition — same structure as the setup-level version; specifies the die grid for alignment at recipe scope. Written at recipe creation.

| Parameter Name | Section | Description | Accepted Values / Type | Example Value |
|---|---|---|---|---|
| *(same parameters as File 10 — DieAlignment.dat_block.ini setup level)* | | | | |

---

## File 48 — `c:\job\<JobName>\<Setup>\Recipes\<R>\DieMapAlignRes.dat_block.ini`

**Purpose:** Stores the die-map alignment result block — the die grid as resolved after die-map alignment completes, recording actual die positions and sizes. Same structure as `DieAlignment.dat_block.ini`.

| Parameter Name | Section | Description | Accepted Values / Type | Example Value |
|---|---|---|---|---|
| *(same parameters as File 10 — DieAlignment.dat_block.ini)* | | | | |

---

## File 49 — `c:\job\<JobName>\<Setup>\Recipes\<R>\ScanOverlapLog.txt`

**Purpose:** Human-readable log of the scan overlap calculation written at scan close — records each overlap component (minimum, detection, alignment, margins, maximum) in both pixels and microns for the last scan.

| Parameter Name | Description | Accepted Values / Type | Example Value |
|---|---|---|---|
| `Pixel size` | Camera pixel size used for µm conversion | Float (µm) | `0.858` |
| `Minimum` | Minimum required overlap [px, µm] | Two integers | `32, 27` |
| `Detection` | Overlap added by detection requirements | Two integers | `0, 0` |
| `User Minimum` | User-configured minimum overlap | Two integers | `0, 0` |
| `Die Alignment` | Overlap added by die alignment uncertainty | Two integers | `86, 74` |
| `Small Dice` | Overlap for small-die handling | Two integers | `0, 0` |
| `Frame Margins` | Overlap reserved for frame margins | Two integers | `16, 14` |
| `Maximum` | Maximum available overlap | Two integers | `576, 494` |
| `Scan` | Final computed scan overlap used | Two integers | `86, 74` |

---

## File 50 — `c:\job\<JobName>\<Setup>\Recipes\<R>\ScanOverviewImage_<name>.txt`

**Purpose:** Stores the affine transformation matrices mapping the scan overview image pixel coordinates to both the wafer-map and chuck-position coordinate systems. Used to correctly position the overview image in the UI.

| Parameter Name | Section | Description | Accepted Values / Type | Example Value |
|---|---|---|---|---|
| `I_2_WM_X` | `[ScanOverviewImage]` | X-row of image-to-wafer-map transform (R11, R12, Tx) | Three space-separated floats | `57.8764648438  0.0000000000  -13742.4000000000` |
| `I_2_WM_Y` | `[ScanOverviewImage]` | Y-row of image-to-wafer-map transform | Three space-separated floats | `0.0000000000  57.8764648438  0.0000000000` |
| `I_2_CP_X` | `[ScanOverviewImage]` | X-row of image-to-chuck-position transform | Three space-separated floats | `57.8745273654  0.3628219499  -120885.3096394868` |
| `I_2_CP_Y` | `[ScanOverviewImage]` | Y-row of image-to-chuck-position transform | Three space-separated floats | `-0.3713251890  57.8761961291  -125448.5273679541` |

---

## File 51 — `c:\job\<JobName>\<Setup>\Recipes\<R>\ImageProcessing.log`

**Purpose:** Sparse state log written by the image-processing module at scan start/end. Typically contains a single line recording whether previous alignment data existed; appended during scan run events.

| Parameter Name | Description | Accepted Values / Type | Example Value |
|---|---|---|---|
| `_previouseAlignmentDataExists` | Whether valid alignment data from a previous run was found | Boolean 0/1 | `1` |

---

## File 52 — `c:\job\<JobName>\<Setup>\Recipes\<R>\ReferencesInfo.json`

**Purpose:** JSON metadata about the recipe's reference images — flags for clean reference folder and pizza-wafer modes, exclusion from job results, and a list of reference type entries. Written at recipe creation; updated when reference configuration changes.

| Parameter Name | JSON path | Description | Accepted Values / Type | Example Value |
|---|---|---|---|---|
| `UseCleanReferenceFolder` | root | Use a dedicated clean reference folder for storage | Boolean | `false` |
| `PeformCleanOnPizza` | root | Create clean reference using a pizza wafer | Boolean | `false` |
| `ExcludeReferenceFromJob` | root | Exclude the reference wafer from job result statistics | Boolean | `false` |
| `RecipeID` | root | GUID of the owning recipe | UUID string | `178523e8-376e-4fbe-994d-479a47b3615a` |
| `ReferenceMetaDataList` | root | Array of reference metadata entries | JSON array | *(see below)* |
| `ReferenceType` | `ReferenceMetaDataList[N]` | Reference type code (1=Die reference, 2=Clean reference) | Integer | `1` or `2` |

---

## File 53 — `c:\job\<JobName>\<Setup>\Recipes\<R>\OpticLightMetadata\config.ini`

**Purpose:** Configures the optical light scanning and illumination peak detection for light metadata calibration — target chuck positions, intensity acceptance bounds, scan resolution, and iteration limits used by DataServer.

| Parameter Name | Section | Description | Accepted Values / Type | Example Value |
|---|---|---|---|---|
| `NominalDelta` | `[General]` | Nominal delta for light measurement | Float | `0.000000000` |
| `Exist` | `[General]` | Whether light metadata has been measured and stored | Boolean 0/1 | `0` |
| `targetPos_X` | `[General]` | Target chuck X position for light scan (µm) | Float | `0.000000000` |
| `targetPos_Y` | `[General]` | Target chuck Y position for light scan (µm) | Float | `0.000000000` |
| `minX` / `minY` | `[General]` | Scan bounding box minimum corner (µm) | Float | `0.000000000` |
| `maxX` / `maxY` | `[General]` | Scan bounding box maximum corner (µm) | Float | `0.000000000` |
| `Peak` | `[General]` | Detected peak intensity value | Float | `0.000000000` |
| `PeakMinTreshold` | `[General]` | Minimum acceptable peak intensity | Float > 0 | `10.000000000` |
| `PeakMaxTreshold` | `[General]` | Maximum acceptable peak intensity | Float > 0 | `60.000000000` |
| `PeakResolution` | `[General]` | Scan step resolution for peak detection (µm) | Float > 0 | `1.000000000` |
| `MaxIterations` | `[General]` | Maximum number of search iterations | Integer ≥ 1 | `10` |

---

## File 54 — `c:\job\<JobName>\<Setup>\Recipes\<R>\FocusMapping\FocusMapping.ini`

**Purpose:** Comprehensive focus-mapping configuration — autofocus search range, surface quality scoring thresholds, CCS focus parameters, peak-detector settings, focus model creation options, bow measurement, and dice sampling strategy. Written at recipe creation; updated after focus-teach events.

| Parameter Name | Section | Description | Accepted Values / Type | Example Value |
|---|---|---|---|---|
| `AutoFocusRange` | `[Mode]` | Z search range for autofocus (µm) | Integer > 0 | `100` |
| `CreateSurfaceScore` | `[Mode]` | Minimum surface quality score to accept | String enum (`Poor`, `Limited`, `Adequate`, `Good`, `Excellent`) | `Good` |
| `MinMatchModelScore` | `[Mode]` | Minimum model match score to accept | String enum | `Good` |
| `DurationOfOneSite` | `[Mode]` | Maximum time allowed per focus site (seconds) | Integer > 0 | `3` |
| `NumOfDiceToScan` | `[Mode]` | Number of dice to scan for focus map creation | Integer ≥ 1 | `15` |
| `ResolutionMode` | `[Mode]` | Focus point resolution mode | String (`SinglePoint`, …) | `SinglePoint` |
| `SurfaceType` | `[Mode]` | Surface interpolation type | String (`None`, …) | `None` |
| `UseAutoFocus` | `[CCSFocusMapping]` | Enable autofocus during CCS focus mapping | Boolean 0/1 | `1` |
| `IntensityLSL` / `IntensityUSL` | `[CCSFocusMapping]` | Acceptable intensity range for CCS focus | Integer 0–100 | `0` / `101` |
| `Averaging` | `[CCSFocusMapping]` | Enable signal averaging at each focus site | Boolean 0/1 | `1` |
| `FastProbActiveRange` | `[CCSFocusMapping]` | Active Z range for fast probe (µm) | Integer | `100` |
| `FastProbZStep` | `[CCSFocusMapping]` | Z step for fast probe (µm) | Integer | `10` |
| `PeakFocusMapFocusOperator` | `[PeakDetector]` | Focus quality operator code | Integer | `3` |
| `MinFocusScore` | `[PeakDetector]` | Minimum acceptable focus score (0–100) | Integer 0–100 | `80` |
| `DebugOutputFilePath` | `[PeakDetector]` | Path for debug focus curve output file | Absolute path string | `C:\Temp\FocusCurve.txt` |
| `EScore_Excellent_Score` | `[PeakDetector]` | Score threshold for "Excellent" grade | Integer 0–100 | `95` |
| `EScore_Good_Score` | `[PeakDetector]` | Score threshold for "Good" grade | Integer 0–100 | `90` |
| `EScore_Adequate_Score` | `[PeakDetector]` | Score threshold for "Adequate" grade | Integer 0–100 | `80` |
| `EScore_Limited_Score` | `[PeakDetector]` | Score threshold for "Limited" grade | Integer 0–100 | `50` |
| `EScore_Poor_Score` | `[PeakDetector]` | Score threshold for "Poor" grade | Integer 0–100 | `20` |
| `MaxClusters` | `[FocusModelCreation]` | Maximum number of focus model clusters | Integer ≥ 1 | `1` |
| `MinBlobArea` | `[FocusModelCreation]` | Minimum blob area for model creation (pixels²) | Integer > 0 | `100` |
| `MinModelSize` | `[FocusModelCreation]` | Minimum model size (pixels) | Integer ≥ 1 | `3` |
| `PeakSelectionPolicy` | `[FocusModelCreation]` | Peak selection policy code | Integer | `1` |
| `Range` | `[FocusModelCreation]` | Z range for model creation (µm) | Integer > 0 | `400` |
| `MaxRangeAutoFocus` | `[FocusMapping]` | Maximum Z range for autofocus (µm) | Integer > 0 | `600` |
| `DOFFactor` | `[FocusMapping]` | Depth-of-field factor | Float > 0 | `1` |
| `FactorRangeSurface` | `[FocusMapping]` | Range factor for surface scanning | Float > 0 | `2.5` |
| `FirstSiteRange` | `[FocusMapping]` | Z range for the first focus site (µm) | Integer > 0 | `200` |
| `MinPercentageToCreateSurface` | `[FocusMapping]` | Minimum fraction of sites needed to create surface | Float 0.0–1.0 | `0.8` |
| `MinSitesToCreateSurface` | `[FocusMapping]` | Minimum absolute count of sites to create surface | Integer ≥ 1 | `13` |
| `OutlierRangeFromMedian` | `[FocusMapping]` | Outlier rejection range from median (µm) | Float > 0 | `15` |
| `ReturnEveryXMinutes` | `[FocusMapping]` | Return to home position every N minutes during mapping | Integer > 0 | `3` |
| `MaxSitesForRange` | `[FocusMapping]` | Maximum number of sites used for range estimation | Integer > 0 | `2000` |
| `DensityDice` | `[DiceFromWafer]` | Dice sampling density (dice per mm²) | Integer ≥ 1 | `6` |
| `MaxDiceToScanCircle` | `[DiceFromWafer]` | Maximum dice per scan circle | Integer > 0 | `2000` |
| `MaxSitesAllowed` | `[DiceFromWafer]` | Hard limit on total focus sites | Integer > 0 | `8000` |
| `MinNumOfDiceForAutoFocusScan` | `[DiceFromWafer]` | Minimum dice required to run autofocus scan | Integer ≥ 1 | `15` |
| `Enable` | `[CCSBowMeasurementFocusMapping]` | Enable bow measurement during focus mapping | Boolean 0/1 | `0` |
| `XYTableSpeed` | `[CCSBowMeasurementFocusMapping]` | Stage speed for bow measurement (mm/s) | Integer > 0 | `5` |
| `CalculationMethod` | `[CCSBowMeasurementFocusMapping]` | Bow calculation method code | Integer | `0` |

---

## File 55 — `c:\job\<JobName>\<Setup>\Recipes\<R>\FocusMapping\DieReferenceLocation.json`

**Purpose:** JSON file storing the die reference location used during focus mapping. Contains `null` when no focus-teach has been performed; populated with die coordinates after a focus-teach event.

| Parameter Name | Description | Accepted Values / Type | Example Value |
|---|---|---|---|
| *(root value)* | Die reference location in focus mapping coordinate system | JSON object with die coordinates, or `null` | `null` |

---

## File 56 — `c:\job\<JobName>\<Setup>\Recipes\<R>\FocusMapping\FocusPointsForScan.xml`

**Purpose:** XML file defining the calculated focus measurement point positions for use during the scan. Generated only after a focus-teach event; not present in recipes where focus mapping has not been performed.

| Parameter Name | Description | Accepted Values / Type | Example Value |
|---|---|---|---|
| *(all parameters)* | Focus point spatial coordinates and metadata | XML elements | NOT FOUND |

---

## File 57 — `c:\job\<JobName>\<Setup>\Recipes\<R>\FocusMapping\Model_<guid>\FocusModel.ini`

**Purpose:** Per-model focus map data file containing the focus model parameters for one GUID-named model cluster. Generated only after a focus-teach event; directory and file do not exist until focus mapping is performed.

| Parameter Name | Description | Accepted Values / Type | Example Value |
|---|---|---|---|
| *(all parameters)* | Focus model geometry, Z range, quality scores | INI key=value | NOT FOUND |

---

## File 58 — `c:\job\<JobName>\<Setup>\Recipes\<R>\.dc_cache\TransactionsHistory.ini`

**Purpose:** Internal migration/transaction history file used by RMS to track which recipe data namespace entities have been deprecated and migrated to the current schema version. Each key encodes a fully qualified namespace path; value `1` confirms the migration is complete.

| Parameter Name | Description | Accepted Values / Type | Example Value |
|---|---|---|---|
| `Namespace.*\|RecipePartsCollection\|CleanReferenceParams` | Migration record for CleanReferenceParams entity | Integer (1=migrated) | `1` |
| `Namespace.*\|RecipePartsCollection\|CleanReference` | Migration record for CleanReference entity | Integer (1=migrated) | `1` |
| `Namespace.*\|ScenariosMetadataCollection_Runtime\|ScenarioMetadataFocusMapping` | Migration record for FocusMapping scenario metadata | Integer (1=migrated) | `1` |
| `Namespace.*\|ScenarioMetadataFocusMapping_Runtime\|BowMeasurementCCSFocusMappingParameter` | Migration record for bow measurement parameter | Integer (1=migrated) | `1` |

---

## File 59 — `c:\job\<JobName>\<Setup>\Recipes\<R>\TrainData\Die.ini`

**Purpose:** Trained die geometry file capturing pixel size, frame dimensions, die step, all four corner positions in chuck coordinates, unique-pattern alignment data, and wafer/die type settings — written during the training workflow by AOI_Main.

| Parameter Name | Section | Description | Accepted Values / Type | Example Value |
|---|---|---|---|---|
| `PixelSize_X` | `[DIE]` | Trained pixel size in X (µm/pixel) | Float > 0 | `0.857650914714166` |
| `PixelSize_Y` | `[DIE]` | Trained pixel size in Y (µm/pixel) | Float > 0 | `0.857650914714166` |
| `FrameSizeX` | `[DIE]` | Camera frame width (pixels) | Integer > 0 | `1280` |
| `FrameSizeY` | `[DIE]` | Camera frame height (pixels) | Integer > 0 | `1280` |
| `Step_X` | `[DIE]` | Die step in X (pixels at training magnification) | Integer > 0 | `3708` |
| `Step_Y` | `[DIE]` | Die step in Y (pixels at training magnification) | Integer > 0 | `16910` |
| `ChuckPosX` | `[TL_CORNER]` | Top-left die corner X position in chuck space (µm) | Float | `-1609.831` |
| `ChuckPosY` | `[TL_CORNER]` | Top-left die corner Y position in chuck space (µm) | Float | `-7670.745` |
| `ChuckPosX` | `[RB_CORNER]` | Right-bottom die corner X in chuck space (µm) | Float | `2020.001` |
| `ChuckPosY` | `[RB_CORNER]` | Right-bottom die corner Y in chuck space (µm) | Float | `9156.367` |
| `ChuckPosX` | `[TR_CORNER]` | Top-right die corner X in chuck space (µm) | Float | `1920.482` |
| `ChuckPosY` | `[TR_CORNER]` | Top-right die corner Y in chuck space (µm) | Float | `-7690.504` |
| `ChuckPosX` | `[NEXT_TL_CORNER]` | Next die top-left corner X (µm) | Float | `2097.993` |
| `ChuckPosY` | `[NEXT_TL_CORNER]` | Next die top-left corner Y (µm) | Float | `9239.072` |
| `DiePitchCorrected` | `[ALIGNMENT_DATA]` | Whether die pitch has been corrected | Boolean 0/1 | `1` |
| `UP_FileName` | `[ALIGNMENT_DATA]` | Unique pattern model filename | String | `UniquePattern.mod` |
| `UP_SearchEngine` | `[ALIGNMENT_DATA]` | Search engine for unique pattern matching | Integer | `0` |
| `UP_Offset_X` | `[ALIGNMENT_DATA]` | Unique pattern X offset within die (pixels) | Integer | `0` |
| `UP_Offset_Y` | `[ALIGNMENT_DATA]` | Unique pattern Y offset within die (pixels) | Integer | `9694` |
| `UP_CenterInDie_X` | `[ALIGNMENT_DATA]` | Unique pattern center X in die coordinates (pixels) | Float | `127.5` |
| `UP_CenterInDie_Y` | `[ALIGNMENT_DATA]` | Unique pattern center Y in die coordinates (pixels) | Float | `9821.5` |
| `UP_Size_X` | `[ALIGNMENT_DATA]` | Unique pattern search ROI width (pixels) | Integer > 0 | `256` |
| `UP_Size_Y` | `[ALIGNMENT_DATA]` | Unique pattern search ROI height (pixels) | Integer > 0 | `256` |
| `Aligned` | `[ALIGNMENT_DATA]` | Whether alignment was completed successfully | Boolean 0/1 | `1` |
| `UseGMF` | `[WaferType]` | Use GMF for wafer type recognition | Boolean 0/1 | `0` |
| `DieUncertanty_um` | `[WaferType]` | Die alignment uncertainty (µm) | Integer > 0 | `500` |
| `MaxWaferRotate_deg` | `[WaferType]` | Maximum allowed wafer rotation (degrees) | Integer > 0 | `5` |
| `MaxStdForAlignment` | `[WaferType]` | Maximum allowed alignment standard deviation (µm) | Integer > 0 | `200` |
| `Step_X` | `[DIE_REFERENCE]` | Reference die step in X (µm) | Float > 0 | `4205.720` |
| `Step_Y` | `[DIE_REFERENCE]` | Reference die step in Y (µm) | Float > 0 | `19738.337` |
| `Size_X` | `[DIE_REFERENCE]` | Reference die width (µm) | Float > 0 | `4116.580` |
| `Size_Y` | `[DIE_REFERENCE]` | Reference die height (µm) | Float > 0 | `19644.607` |
| `Margin_X` / `Margin_Y` | `[DIE_REFERENCE]` | Reference die margin (µm) | Integer ≥ 0 | `0` |

---

## File 60 — `c:\job\<JobName>\<Setup>\Recipes\<R>\TrainData\DieRefToTrain.txt`

**Purpose:** Stores the 2D affine transform mapping from the die reference image coordinate system to the training image coordinate system, captured during the training workflow.

| Parameter Name | Section | Description | Accepted Values / Type | Example Value |
|---|---|---|---|---|
| `DR_2_TI_X` | `[DieRefToTrainImage]` | X-row of ref→train affine matrix (R11, R12, Tx) | Space-separated string: 3 floats | `1 0 1114.36704139293` |
| `DR_2_TI_Y` | `[DieRefToTrainImage]` | Y-row of ref→train affine matrix (R21, R22, Ty) | Space-separated string: 3 floats | `0 1 1120.96597481518` |
| `DR_2_TI_Theta` | `[DieRefToTrainImage]` | Rotation angle of the transform (degrees) | Float | `0.0000000` |
| `DR_2_TI_Gamma` | `[DieRefToTrainImage]` | Shear angle of the transform | Float | `0.0000000` |
| `DR_2_TI_Scale` | `[DieRefToTrainImage]` | Scale factors (X Y) | Two space-separated floats | `1.00000000 1.00000000` |
| `DR_2_TI_Shift` | `[DieRefToTrainImage]` | Translation shift (X Y) in pixels | Two space-separated floats | `1114.367 1120.966` |

---

## File 61 — `c:\job\<JobName>\<Setup>\Recipes\<R>\TrainData\FrameToChuck.ini`

**Purpose:** Stores the 2×3 affine transform mapping camera frame pixel coordinates to chuck (stage) coordinates in µm, captured during the training workflow by AOI_Main.

| Parameter Name | Section | Description | Accepted Values / Type | Example Value |
|---|---|---|---|---|
| `F2C_X` | `[FrameToChuck]` | X-row of frame-to-chuck affine matrix (R11, R12, Tx) | Three space-separated floats | `0.8576508809  0.0002406744  -549.0505954039` |
| `F2C_Y` | `[FrameToChuck]` | Y-row of frame-to-chuck affine matrix (R21, R22, Ty) | Three space-separated floats | `-0.0002406744  0.8576508809  -548.7425322058` |

---

## File 62 — `c:\job\<JobName>\<Setup>\Recipes\<R>\TrainData\DieImage\*.ini`

**Purpose:** Per-training-image metadata `.ini` files stored alongside the training die `.tif` images. Not present in observed recipe — directory contains only `.tif` image files; `.ini` companions are not generated for this recipe configuration.

| Parameter Name | Description | Accepted Values / Type | Example Value |
|---|---|---|---|
| *(all parameters)* | Training image metadata | INI key=value | NOT FOUND |

---

## File 63 — `c:\job\<JobName>\<Setup>\Recipes\<R>\TrainData\ZonesVectorInfo.csv`

**Purpose:** CSV file recording zone vector information for trained die zones. Not present in observed recipe — requires a specific training workflow step to generate.

| Parameter Name | Description | Accepted Values / Type | Example Value |
|---|---|---|---|
| *(all parameters)* | Zone vector data columns | CSV | NOT FOUND |

---

## File 64 — `c:\job\<JobName>\<Setup>\Recipes\<R>\ReferenceBackup\ZoomLevels.ini`

**Purpose:** Backup copy of `ZoomLevels.ini` saved before a reference update event. Identical structure to the active `ZoomLevels.ini` (File 28). Used to restore the previous zoom pyramid if the new reference is rejected.

| Parameter Name | Section | Description | Accepted Values / Type | Example Value |
|---|---|---|---|---|
| *(same parameters as File 28 — ZoomLevels.ini)* | | | | |

---

## File 65 — `c:\job\<JobName>\<Setup>\Recipes\<R>\SW_QA-*\OpticsPreset.ini`

**Purpose:** QA snapshot of the optics/robot preset saved in a QA subfolder (e.g., `SW_QA-5`). Records the robot setup name and chuck center position at time of capture.

| Parameter Name | Section | Description | Accepted Values / Type | Example Value |
|---|---|---|---|---|
| `Name` | `[RobotSetup]` | Robot/EFEM configuration file name | String | `PD_8_106448_ARC.cfg` |
| `CenterX` | `[Chuck]` | Chuck center X position at time of QA capture (µm) | Float | `158684.0625` |
| `CenterY` | `[Chuck]` | Chuck center Y position at time of QA capture (µm) | Float | `138935.140625` |
| `CenterZ` | `[Chuck]` | Chuck center Z position at time of QA capture (µm) | Float | `-377.3` |

---

## File 66 — `c:\job\<JobName>\<Setup>\Recipes\<R>\WaferAlignData\AlignmentData.ini`

**Purpose:** Records the total elapsed time for the last wafer alignment run in milliseconds. Written fresh by AOI_Main at the start of every scan run.

| Parameter Name | Section | Description | Accepted Values / Type | Example Value |
|---|---|---|---|---|
| `AlignmentTime` | `[General]` | Total time taken for wafer alignment (ms) | Integer ≥ 0 | `6941` |

---

## File 67 — `c:\job\<JobName>\<Setup>\Recipes\<R>\WaferAlignData\Alignment_PatFindRtp.txt`

**Purpose:** Text log of the alignment pattern-find RTP parameters active during the last wafer alignment run — minimum scores, search mode flags, and rotation search settings. Written by AOI_Main on each run.

| Parameter Name | Description | Accepted Values / Type | Example Value |
|---|---|---|---|
| `Minimum Score` | Minimum match score required for alignment success | Integer 0–100 | `85` |
| `Minimum Start` | Starting score threshold for the search | Integer 0–100 | `90` |
| `Reduce Delta` | Score reduction step between search iterations | Integer > 0 | `10` |
| `Minimum Target Score` | Target pattern minimum score | Integer 0–100 | `0` |
| `Retry With GMF` | Whether GMF is used as fallback if initial search fails | `[X]` (enabled) / `[ ]` (disabled) | `[ ]` |
| `Use Actual Model` | Use the actual stored model (not approximation) | `[X]` / `[ ]` | `[ ]` |
| `Use Model Uncertanty` | Include model uncertainty in search | `[X]` / `[ ]` | `[ ]` |
| `Search In All Image` | Search entire image (not just ROI) | `[X]` / `[ ]` | `[ ]` |
| `Model Full Coverage` | Require full model coverage | `[X]` / `[ ]` | `[ ]` |
| `Preprocess Target Image` | Apply pre-processing before matching | `[X]` / `[ ]` | `[X]` |
| `Search With Rotate` | Enable rotation in pattern search | `[X]` / `[ ]` | `[X]` |
| `Search Angle` | Rotation search range (degrees) | Float > 0 | `5.0` |

---

## File 68 — `c:\job\<JobName>\<Setup>\Recipes\<R>\WaferAlignData\AlignmentStatisticsTime.txt`

**Purpose:** Records timing statistics for alignment sub-operations on the last run — image grab and stage move counts, totals, and averages in milliseconds. Written by AOI_Main on each run.

| Parameter Name | Description | Accepted Values / Type | Example Value |
|---|---|---|---|
| `Grabbing Counter` | Number of image grabs during alignment | Integer ≥ 0 | `10` |
| Grabbing `Total` | Total time for all grabs (ms) | Integer ≥ 0 | `374` |
| Grabbing `Average` | Average time per grab (ms) | Float ≥ 0 | `37.400002` |
| `Moving Counter` (stage X/Y) | Number of X/Y stage moves | Integer ≥ 0 | `10` |
| Moving `Total` (stage X/Y) | Total time for X/Y moves (ms) | Integer ≥ 0 | `1483` |
| Moving `Average` (stage X/Y) | Average time per X/Y move (ms) | Float ≥ 0 | `148.300003` |
| `Moving Counter` (stage Z) | Number of Z stage moves | Integer ≥ 0 | `10` |
| Moving `Total` (stage Z) | Total time for Z moves (ms) | Integer ≥ 0 | `142` |
| Moving `Average` (stage Z) | Average time per Z move (ms) | Float ≥ 0 | `14.200000` |

---

## File 69 — `c:\job\<JobName>\<Setup>\Recipes\<R>\WaferAlignData\Alignment_PatRes.txt`

**Purpose:** Tabular log of pattern-recognition results for each alignment point on the last run — die position (col/row), time, error, uncertainty thresholds, prediction, score, and outcome status string.

| Column Name | Description | Accepted Values / Type | Example Value |
|---|---|---|---|
| `#` | Point index | Integer ≥ 0 | `0` |
| `Col` | Die column of the alignment point | Integer | `29` |
| `Row` | Die row of the alignment point | Integer | `7` |
| `Time[us]` | Time for this point search (µs) | Integer ≥ 0 | UNKNOWN (blank in log) |
| `Err` | Position error (µm) | Float | `75` |
| `Uncert` | Uncertainty threshold (µm) | Float | `200` |
| `1stLevel` | First-level search threshold | Integer | `200` |
| `Prediction` X/Y | Predicted position offset | Float | `-0.0 / 0.0` |
| `Score` | Pattern match score | Float 0–100 | UNKNOWN (blank when skipped) |
| `Rotate` | Matched rotation | Float | UNKNOWN |
| Status | Outcome description string | String | `Skipped - search ROI out of frame` |

---

## File 70 — `c:\job\<JobName>\<Setup>\Recipes\<R>\WaferAlignData\Alignment_Stat.txt`

**Purpose:** Summary statistics of alignment fit quality — shows residuals for affine and orthogonal fits per alignment point. Empty ("No points") when no alignment points matched on the last run.

| Column Name | Description | Accepted Values / Type | Example Value |
|---|---|---|---|
| `Reference` | Reference position coordinates | Float | UNKNOWN (no points in observed instance) |
| `Inspection` | Inspection position coordinates | Float | UNKNOWN |
| `Res_Afine` | Affine fit residual | Float | UNKNOWN |
| `Res_Ortho` | Orthogonal fit residual | Float | UNKNOWN |

---

## File 71 — `c:\job\<JobName>\<Setup>\Recipes\<R>\DebugAFMapping\FocusMappingDebug_*.txt`

**Purpose:** Debug log files appended during focus-mapping scan events. Not present in observed recipe — directory is empty; debug logging is not currently enabled for this recipe.

| Parameter Name | Description | Accepted Values / Type | Example Value |
|---|---|---|---|
| *(all parameters)* | Focus mapping debug entries | Text log | NOT FOUND |

---

## File 72 — `c:\job\<JobName>\<Setup>\Recipes\<R>\s_FrameData.dat.md`

**Purpose:** XML schema descriptor for the companion binary `s_FrameData.dat` file — defines all 32 field names, types, byte offsets, and the record size (160 bytes) for the frame data records written during scanning. Acts as documentation/metadata for the binary format.

| Parameter Name | XML Attribute | Description | Accepted Values / Type | Example Value |
|---|---|---|---|---|
| `RecordSize` | `Size` | Size of each binary frame record (bytes) | Integer | `160` |
| `frameIdx` | `Name` / `Id` / `Offset` / `Vartype` | Sequential frame index | Binary field descriptor | Offset=0, Vartype=3 |
| `frameStatus` | field | Frame processing status flags | Binary field descriptor | UNKNOWN offset |
| `ScanStrip` | field | Scan strip number | Binary field descriptor | UNKNOWN |
| `Row` | field | Die row index of this frame | Binary field descriptor | UNKNOWN |
| `Col` | field | Die column index of this frame | Binary field descriptor | UNKNOWN |
| `Align_X` | field | Frame alignment result X (µm) | Binary field descriptor | UNKNOWN |
| `Align_Y` | field | Frame alignment result Y (µm) | Binary field descriptor | UNKNOWN |
| `AlignScore` | field | Frame alignment match score | Binary field descriptor | UNKNOWN |
| `FrameStart_X` / `_Y` / `_Z` | field | Frame start position in chuck space (µm) | Binary field descriptor | UNKNOWN |
| `InspEnd_X` / `_Y` / `_Z` | field | Frame inspection end position (µm) | Binary field descriptor | UNKNOWN |
| `ScanId` | field | Scan session identifier | Binary field descriptor | UNKNOWN |
| `ReAlignFrameScore` | field | Re-alignment score for this frame | Binary field descriptor | UNKNOWN |
| `ReAlignFrameError` | field | Re-alignment error for this frame | Binary field descriptor | UNKNOWN |
| *(additional fields)* | | 32 fields total; remaining names UNKNOWN | Binary field descriptor | UNKNOWN |

---

## File 73 — `c:\job\<JobName>\<Setup>\Recipes\<R>\ScenarioMetadataGrab.xml`

**Purpose:** XML configuration for defect image grab scenarios. Not found in Diced or ScanAreaOnly recipe instances; found only in `ValidationJob`. The file is a large binary-serialized XML (~44 KB) whose internal field structure cannot be determined from the observed binary.

| Parameter Name | Description | Accepted Values / Type | Example Value |
|---|---|---|---|
| *(all parameters)* | Grab scenario metadata | Binary XML | NOT FOUND in Diced / ScanAreaOnly recipes |

---

## File 74 — `c:\job\<JobName>\<Setup>\CurrWaferSurfaceInterpolation.ini` / `.md`

**Purpose:** Stores the current wafer surface interpolation data (height map) generated during an active scan for the wafer currently on the chuck. Written and updated by AOI_Main during scan; not present between runs.

| Parameter Name | Description | Accepted Values / Type | Example Value |
|---|---|---|---|
| *(all parameters)* | Wafer surface height interpolation data | INI key=value / markdown schema | NOT FOUND (not present between runs) |

---

## File 75 — `c:\job\ValidationJob\VcamInstallerGuid.txt`

**Purpose:** Single-value text file storing the GUID of the VCam installer that created or last configured the ValidationJob. Used by external tools to verify VCam installation identity.

| Parameter Name | Description | Accepted Values / Type | Example Value |
|---|---|---|---|
| *(file content — single line)* | VCam installer unique identifier | UUID string | `0f79e46a-a13a-4779-8b21-541a64d4e0b7` |

---

## File 76 — `c:\job\<JobName>\<Setup>\DieAlignment.dat` *(text-passing)*

**Purpose:** Binary file containing structured die alignment data for the setup level. Carries packed die position, alignment residual, and model registration records. Passes the text-heuristic filter due to ASCII headers but is internally binary-structured.

| Parameter Name | Description | Accepted Values / Type | Example Value |
|---|---|---|---|
| *(all parameters)* | Structured binary — die alignment records (positions, residuals, model data) | Binary (SHA-256 hash only; no text diff) | UNKNOWN |

---

## File 77 — `DieMapping.dat`, `DieRegPos.dat`, `DieMapRegPos.dat`, `WaferInfo.dat`, `zones.dat`, `Job.dat`

**Purpose:** Binary data files carrying structured die map, registration positions, wafer information, zone definitions, and job data between modules. Use structured binary encoding with ASCII-prefixed headers; pass the text heuristic but must be treated as binary for audit purposes.

| File | Description | Parameter Structure | Example Value |
|---|---|---|---|
| `DieMapping.dat` | Packed die-to-wafer-map index mapping | Binary integer array with die indices | UNKNOWN — binary |
| `DieRegPos.dat` | Packed float coordinates for die registration positions | Binary float array (4 corner positions × X/Y) | UNKNOWN — binary |
| `DieMapRegPos.dat` | Packed float coordinates for die-map registration positions | Binary float array (same structure as DieRegPos.dat) | UNKNOWN — binary |
| `WaferInfo.dat` | Structured wafer metadata and die-map parameters | Binary records with ASCII header | UNKNOWN — binary |
| `zones.dat` | Zone definition data (compressed zone boundaries) | Binary compressed zone structure | UNKNOWN — binary |
| `Job.dat` | Job-level parameters | Binary structured data | UNKNOWN — binary |

> **Note for all `.dat` files:** Store SHA-256 hash only on change. Do not attempt to extract or diff text content — values are UNKNOWN from plain-text observation.

---

## Summary Statistics

| Priority | File count (patterns) | Notes |
|---|---|---|
| P1 (Critical/High) | 22 patterns | Full parameter detail available for all observed instances |
| P2 (High/Medium) | 30 patterns | Full detail for most; binary `.dat` files hash-only |
| P3/P4 (Low) | 15 patterns | Log/result files — partial or NOT FOUND |
| Files NOT FOUND (not generated yet) | 6 | FocusPointsForScan.xml, FocusModel.ini, DieImage/*.ini, ZonesVectorInfo.csv, CurrWaferSurfaceInterpolation.*, ScenarioMetadataGrab.xml |
| Binary (UNKNOWN parameters) | 7 | DieAlignment.dat + 6 `.dat` files in File 77 |
