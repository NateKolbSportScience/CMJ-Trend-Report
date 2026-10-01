// Reads every ForceDecks CMJ export in DataFolder (subfolders included) - or the built-in demo
// export when DataFolder is blank - and returns the exact
// columns the CMJ Trend Report expects. Column order, extra/missing columns, header spacing,
// [unit] vs (unit), inch or cm jump height and duplicate tests across files are all handled.
let
    // ---------- helpers --------------------------------------------------------------------
    Key = (h as any) as text =>
        let
            t = Text.Replace(Text.Replace(Text.Replace(if h = null then "" else Text.From(h), Character.FromNumber(65279), ""), "[", "("), "]", ")"),
            words = List.Select(Text.SplitAny(Text.Lower(Text.Trim(t)), " #(tab)#(00A0)"), each _ <> "")
        in
            Text.Combine(words, " "),
    CleanName = (n as any) as nullable text =>
        let parts = if n = null then {} else List.Select(Text.SplitAny(Text.Trim(Text.From(n)), " #(tab)#(00A0)"), each _ <> "")
        in if List.IsEmpty(parts) then null else Text.Combine(parts, " "),
    ToNumber = (v as any) as nullable number =>
        if v = null then null
        else if v is number then v
        else
            let t = Text.Remove(Text.Trim(Text.From(v)), {"%", " ", "#(00A0)"})
            in if t = "" then null else try Number.FromText(t, "en-US") otherwise null,
    ToDate = (v as any) as nullable date =>
        if v = null then null
        else if v is date then v
        else if v is datetime then DateTime.Date(v)
        else
            let t = Text.Trim(Text.From(v))
            in if t = "" then null
               else try Date.FromText(t, ExportCulture)
               otherwise try DateTime.Date(DateTime.FromText(t, ExportCulture))
               otherwise try Date.FromText(Text.BeforeDelimiter(t, " "), ExportCulture)
               otherwise null,
    ToTime = (v as any) as nullable time =>
        if v = null then null
        else if v is time then v
        else
            let t = Text.Trim(Text.From(v))
            in if t = "" then null
               else try Time.FromText(t, ExportCulture)
               otherwise try DateTime.Time(DateTime.FromText(t, ExportCulture))
               otherwise null,
    // "12.3 L" -> -12.3, "8.1 R" -> 8.1 (left negative, right positive)
    Asym = (v as any) as nullable number =>
        if v = null then null
        else if v is number then v
        else
            let
                tokens = List.Select(Text.SplitAny(Text.Upper(Text.Remove(Text.Trim(Text.From(v)), {"%"})), " ()#(00A0)"), each _ <> ""),
                nums = List.RemoveNulls(List.Transform(tokens, each try Number.FromText(_, "en-US") otherwise null)),
                n = List.First(nums, null),
                isLeft = List.Contains(tokens, "L") or List.Contains(tokens, "LEFT")
            in
                if n = null then null else if isLeft then -Number.Abs(n) else Number.Abs(n),
    Converters = [
        text = (v) => if v = null then null else let t = Text.Trim(Text.From(v)) in if t = "" then null else t,
        number = ToNumber,
        int = (v) => let n = ToNumber(v) in if n = null then null else Int64.From(n),
        date = ToDate,
        time = ToTime
    ],
    Types = [text = type text, number = type number, int = Int64.Type, date = type date, time = type time],

    // ---------- choose the data ------------------------------------------------------------
    // DataFolder left blank -> the simulated demo export built into this file (works on any computer).
    // DataFolder set        -> every CSV in that folder and its subfolders.
    UseDemo = DataFolder = null or Text.Trim(Text.From(DataFolder)) = "",
    DemoCsv = Binary.Decompress(Binary.FromText("DEMO_DATA_BASE64", BinaryEncoding.Base64), Compression.Deflate),
    Empty = #table({"Content", "Name", "Extension"}, {}),
    Probe = if UseDemo then [HasError = true] else try Table.RowCount(Folder.Files(DataFolder)),
    AllFiles =
        if UseDemo then #table({"Content", "Name", "Extension"}, {{DemoCsv, "forcedecks_cmj_demo.csv", ".csv"}})
        else if Probe[HasError] then Empty
        else Folder.Files(DataFolder),
    CsvFiles = Table.SelectRows(AllFiles, each Text.Lower([Extension]) = ".csv" and not Text.StartsWith([Name], "~$")),
    ReadCsv = (content as binary) as table =>
        let
            first = try Lines.FromBinary(content, null, null, 65001){0} otherwise "",
            delimiter = if List.Count(Text.Split(first, ";")) > List.Count(Text.Split(first, ",")) then ";" else ",",
            promoted = Table.PromoteHeaders(Csv.Document(content, [Delimiter = delimiter, Encoding = 65001, QuoteStyle = QuoteStyle.Csv]), [PromoteAllScalars = true]),
            old = Table.ColumnNames(promoted),
            keys = List.Transform(old, Key),
            unique = List.Accumulate(List.Positions(keys), {}, (acc, i) => acc & {if List.Contains(acc, keys{i}) then keys{i} & " #" & Text.From(i) else keys{i}})
        in
            Table.RenameColumns(promoted, List.Zip({old, unique})),
    Tables = List.RemoveNulls(List.Transform(CsvFiles[Content], each try Table.Buffer(ReadCsv(_)) otherwise null)),
    Combined = if List.IsEmpty(Tables) then #table({}, {}) else Table.Combine(Tables),

    // Keep CMJ rows only when a file holds several ForceDecks tests (single-leg CMJ excluded)
    CmjOnly = if not Table.HasColumns(Combined, "test type") then Combined
        else Table.SelectRows(Combined, each
            let t = if [test type] = null then "" else Text.Lower(Text.From([test type]))
            in (Text.Contains(t, "cmj") or Text.Contains(t, "countermovement"))
               and not Text.Contains(t, "sl") and not Text.Contains(t, "single") and not Text.Contains(t, "rebound")),

    // ---------- map whatever is there onto the report's columns ---------------------------
    // {output column, accepted export headers, type}
    Spec = {
        {"Name", {"Name", "Athlete", "Athlete Name"}, "text"},
        {"ExternalId", {"ExternalId", "External Id"}, "text"},
        {"Test Type", {"Test Type", "Test"}, "text"},
        {"Date", {"Date", "Test Date"}, "date"},
        {"Time", {"Time", "Test Time"}, "time"},
        {"BW [KG]", {"BW [KG]", "Bodyweight [kg]", "Body Weight [kg]"}, "number"},
        {"Reps", {"Reps", "Repetitions"}, "int"},
        {"Tags", {"Tags"}, "text"},
        {"Additional Load [lb]", {"Additional Load [lb]", "Additional Load [lbs]"}, "int"},
        {"Jump Height (Imp-Mom) (cm)", {"Jump Height (Imp-Mom) [cm]"}, "number"},
        {"__JumpHeightIn", {"Jump Height (Imp-Mom) in Inches [in]", "Jump Height (Imp-Mom) [in]"}, "number"},
        {"Contraction Time (ms)", {"Contraction Time [ms]"}, "int"},
        {"Peak Power / BM (W/kg)", {"Peak Power / BM [W/kg]", "Peak Power/BM [W/kg]"}, "number"},
        {"Bodyweight in Pounds [lbs] ", {"Bodyweight in Pounds [lbs]"}, "number"},
        {"CMJ Stiffness [N/m] ", {"CMJ Stiffness [N/m]"}, "int"},
        {"Vertical Velocity at Takeoff (m/s)", {"Vertical Velocity at Takeoff [m/s]"}, "number"},
        {"Eccentric Braking RFD (N/s)", {"Eccentric Braking RFD [N/s]"}, "int"},
        {"Positive Impulse [N s] ", {"Positive Impulse [N s]"}, "number"},
        {"Concentric Mean Force [N] ", {"Concentric Mean Force [N]"}, "int"},
        {"Concentric Impulse % (Asym) (%)", {"Concentric Impulse % (Asym) (%)", "Concentric Impulse % (Asym)"}, "text"},
        {"Velocity at Peak Power [m/s] ", {"Velocity at Peak Power [m/s]"}, "number"},
        {"Force at Zero Velocity (N)", {"Force at Zero Velocity [N]"}, "int"},
        {"Countermovement Depth [cm] ", {"Countermovement Depth [cm]"}, "number"},
        {"Eccentric Braking Impulse % (Asym) (%)", {"Eccentric Braking Impulse % (Asym) (%)", "Eccentric Braking Impulse % (Asym)"}, "text"}
    },
    Cols = Table.ColumnNames(CmjOnly),
    Resolve = (aliases as list) as nullable text => List.First(List.Select(List.Transform(aliases, Key), each List.Contains(Cols, _)), null),
    Shaped = Table.FromRecords(
        Table.TransformRows(CmjOnly, (r) =>
            Record.FromList(
                List.Transform(Spec, (s) => let k = Resolve(s{1}) in if k = null then null else Record.Field(Converters, s{2})(Record.Field(r, k))),
                List.Transform(Spec, each _{0}))),
        List.Transform(Spec, each _{0}), MissingField.UseNull),

    // Exports set to inches: convert jump height to cm (the report is all-metric for lengths)
    Filled = Table.FromRecords(
        Table.TransformRows(Shaped, (r) =>
            Record.TransformFields(r, {
                {"Jump Height (Imp-Mom) (cm)", (x) => if x <> null then x else if r[__JumpHeightIn] <> null then r[__JumpHeightIn] * 2.54 else null},
                {"Bodyweight in Pounds [lbs] ", (x) => if x <> null then x else if r[#"BW [KG]"] <> null then r[#"BW [KG]"] * 2.20462 else null}})),
        Table.ColumnNames(Shaped), MissingField.UseNull),
    NoHelper = Table.RemoveColumns(Filled, {"__JumpHeightIn"}),

    EccDirection = Table.AddColumn(NoHelper, "Eccentric Braking Impulse % (Asym) Direction", each Asym([#"Eccentric Braking Impulse % (Asym) (%)"])),
    ConcDirection = Table.AddColumn(EccDirection, "Concentric Impulse % (Asym) Direction", each let n = Asym([#"Concentric Impulse % (Asym) (%)"]) in if n = null then null else Int64.From(n)),

    // ---------- athletes: tidy names, number them, optionally anonymise --------------------
    Tidy = Table.TransformColumns(ConcDirection, {{"Name", CleanName}}),
    Valid = Table.SelectRows(Tidy, each [Name] <> null and [Date] <> null),
    Names = List.Sort(List.Distinct(Valid[Name])),
    Index = Record.FromList(List.Numbers(1, List.Count(Names)), Names),
    WithId = Table.AddColumn(Valid, "athleteid.Index.1", each Record.Field(Index, [Name])),
    Display = Table.TransformColumns(WithId, {{"Name", each if AnonymizeNames then "athlete_" & Text.PadStart(Text.From(Record.Field(Index, _)), 2, "0") else _}}),

    Deduped = Table.Distinct(Display),
    Typed = Table.TransformColumnTypes(Deduped,
        List.Transform(List.Select(Spec, each not Text.StartsWith(_{0}, "__")), each {_{0}, Record.Field(Types, _{2})}) & {
            {"Eccentric Braking Impulse % (Asym) Direction", type number},
            {"Concentric Impulse % (Asym) Direction", Int64.Type},
            {"athleteid.Index.1", Int64.Type}})
in
    Typed
