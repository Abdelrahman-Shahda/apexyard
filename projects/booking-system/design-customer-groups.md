# Design Spec: Customer Groups — spark-tenant-admin-web

**Status**: Draft
**Authors**: Nour (UI Designer) + Iman (UX Designer)
**Date**: 2026-06-01
**PRD**: `projects/booking-system/prd-customer-groups.md`
**Tech Design**: `projects/booking-system/techdesign-customer-groups.md`
**Format**: Implementable text + ASCII — no Figma round-trip required.

---

## Frontmatter — Screen-to-Ticket Cross-Reference

| Screen / Spec | US | Frontend Ticket |
|---|---|---|
| Customer Groups list view | US-1 (AC-3,4), US-3 (AC-4) | Linked from US-1 frontend ticket (file as sub-issue under epic #707) |
| Group create / edit modal | US-1 (AC-1,2,3) | Linked from US-1 frontend ticket |
| Group detail — Members tab | US-3 (AC-1,2,3) | Linked from US-3 frontend ticket |
| Group detail — Import tab | US-2 (all ACs) | Linked from US-2 frontend ticket |
| Group detail — Settings tab | US-7 (AC-1,2) | Linked from US-7 frontend ticket |
| Excel import flow (inline in Import tab) | US-2 (AC-3,4,5,6,7,8,9) | Linked from US-2 frontend ticket |
| Space edit — Access section | US-4 (all ACs) | Linked from US-4 frontend ticket |
| Soft-delete confirmation dialog | US-7 (AC-1,2) | Component spec — part of US-7 frontend ticket |
| Auto-revert banner | US-7 (AC-2) | Component spec — part of US-7 frontend ticket |

> NOTE: Ticket numbers above are placeholders. The parallel ticket-filing agent is filing issues under epic apessolutions/booking-system#707. Replace with real `#NNN` references once those issues exist.

---

## Visual System Reminder

The app uses **MUI v5** + **Minimals theme**. All new components reuse, not redefine:

| Token | Value / source |
|---|---|
| Typography | `h4` headings, `body2` body — match existing `CustomerDetailsView`, `SpaceNewEdit` |
| Spacing unit | 8 px (MUI default; use `sx={{ p: 3 }}`, `spacing={2}`, etc.) |
| Card | `<Card>` from `@mui/material` — no custom wrapper needed |
| Page shell | `<DashboardContent>` + `<CustomBreadcrumbs heading links action>` — mandatory on every view |
| Primary action slot | The `action` prop of `CustomBreadcrumbs` — Button with `startIcon={<Iconify icon="mingcute:add-line" />}` |
| Tables | `useTable` hook + `TableHeadCustom` + `TableSkeleton` + `TableNoData` + `TablePaginationCustom` + `Scrollbar` from `src/components/table` |
| Empty state | `<EmptyContent>` from `src/components/empty-content` |
| Confirm dialog | `<ConfirmDialog>` from `src/components/custom-dialog` |
| Form modals | `<Dialog fullWidth maxWidth="sm">` + `<DialogTitle>` + `<DialogContent>` + `<DialogActions>` |
| Form fields | `<Field.Text>`, `<Field.Autocomplete>` from `src/components/hook-form/fields.tsx` |
| Icons | `<Iconify icon="...">` — always via the `Iconify` wrapper, never raw SVG |
| Status labels | `<Label color="success\|error\|warning" variant="soft">` from `src/components/label` |
| Toasts | `toast.success(...)` / `toast.error(...)` from `src/components/snackbar` |
| File upload | `<Upload>` with `useDropzone` under the hood — from `src/components/upload` |
| Scrollable containers | `<Scrollbar>` from `src/components/scrollbar` — wrap any overflow Table |
| Permission gate | `<PermissionGuard requiredPermission={CustomerGroupPermission.X}>` — matches existing pattern in `location-list-view.tsx` |

---

## Screen 1 — Customer Groups List View

**File**: `sections/customer-groups/view/customer-groups-list-view.tsx`

### ASCII Wireframe

```
+------------------------------------------------------------------+
| DashboardContent                                                 |
|  CustomBreadcrumbs                                               |
|  heading: "Customer Groups"                                      |
|  links: [ Dashboard > Customer Groups ]                          |
|  action: [+ New Group]  (Button, variant=contained)              |
+------------------------------------------------------------------+
|  Card                                                            |
|  +------------------------------------------------------------+  |
|  | [  Search groups...  ] [________________] (TextField)      |  |
|  +------------------------------------------------------------+  |
|  | Scrollbar > Table (minWidth: 720)                          |  |
|  | TableHeadCustom                                            |  |
|  | +---------+--------------------+----------+------------+--+  |
|  | | ID      | Name               | Members  | Created At | >|  |
|  | +---------+--------------------+----------+------------+--+  |
|  | | 42      | Compound Residents | 312      | 31 May     | >|  |
|  | | 51      | Tennis Academy     | 48       | 1 Jun      | >|  |
|  | | ...     | ...                | ...      | ...        | >|  |
|  | +---------+--------------------+----------+------------+--+  |
|  |                                                              |  |
|  | TablePaginationCustom (count, page, rowsPerPage)            |  |
|  +------------------------------------------------------------+  |
+------------------------------------------------------------------+
```

### Component Tree

```
CustomerGroupsListView
  DashboardContent
    CustomBreadcrumbs
      heading="Customer Groups"
      links=[{name:"Dashboard",href:"/"},{name:"Customer Groups"}]
      action={
        PermissionGuard[CustomerGroupPermission.add]
          Button[variant=contained, startIcon=<Iconify icon="mingcute:add-line">]
            "New Group"
      }
    CustomerGroupsTable          ← new component
      Card
        CustomerGroupsTableToolbar   ← new component
          Stack[direction=row, spacing=2, sx={{p:2.5}}]
            TextField[placeholder="Search groups...", InputAdornment=<Iconify icon="eva:search-fill">]
        Scrollbar
          Table[size=medium, sx={{minWidth:720}}]
            TableHeadCustom[headLabel=TABLE_HEAD]
            TableBody
              [loading] → [...Array(rowsPerPage)].map → TableSkeleton
              [data]    → groups.map → CustomerGroupTableRow
              TableEmptyRows
              [empty]   → TableNoData
        TablePaginationCustom
```

**TABLE_HEAD columns**:

| id | label | width | align |
|---|---|---|---|
| `id` | `"ID"` | 80 | left |
| `name` | `"Name"` | — (flex) | left |
| `description` | `"Description"` | 240 | left |
| `memberCount` | `"Members"` | 100 | center |
| `createdAt` | `"Created"` | 140 | left |
| `""` | `""` | 56 | — (row chevron) |

**CustomerGroupTableRow** renders:

- `id`: plain text
- `name`: `Typography variant="subtitle2"` (bold)
- `description`: `Typography variant="body2" color="text.secondary" noWrap` — truncate at 40 chars with ellipsis; `Tooltip` with full text on hover
- `memberCount`: `Label variant="soft" color="info"` — e.g. `"312"`; renders `"—"` when `null`
- `createdAt`: formatted `"DD MMM YYYY"` using existing `fDate` util from `src/utils/format-time`
- Row chevron: `IconButton` with `<Iconify icon="eva:chevron-right-fill">` — `onClick` → `router.push(paths.customerGroups.detail(row.id))`

### States

| State | Render |
|---|---|
| Loading | `TableSkeleton` rows (skeleton shimmer per existing pattern) |
| Empty (zero groups) | `TableNoData` component (`notFound=true`); message: "No customer groups yet" |
| Empty search results | `TableNoData`; message: "No groups match your search" |
| Data | Rows per page (default 10); paginated via `TablePaginationCustom` |
| Error | `toast.error("Failed to load groups")` — table body stays empty |

### Interactions

- Typing in the search field debounces 400ms, sets `text` filter, resets to page 1 (mirrors `CustomerTable` pattern).
- Clicking a row navigates to the group detail view: `paths.customerGroups.detail(id)`.
- Clicking "+ New Group" opens the `GroupCreateEditModal` (controlled by a `useBoolean` in the list view).
- After modal save, the list refetches via SWR `mutate`.

### Data Binding

| UI element | DTO field |
|---|---|
| Name cell | `SparkCustomerGroupDto.name` |
| Description cell | `SparkCustomerGroupDto.description` |
| Members badge | `SparkCustomerGroupDto.memberCount` |
| Created cell | `SparkCustomerGroupDto.createdAt` |
| Row key | `SparkCustomerGroupDto.id` |

**API**: `GET /customer-groups?page=N&limit=10&search=<text>` — `SparkCustomerGroupQueryDto` shape.

### PRD AC Mapping

- US-1 AC-3 (empty group allowed — list shows 0 members)
- US-1 AC-4 (tenant-scoped — API already handles; list never shows other tenants' groups)
- US-3 AC-4 (member count visible on list without clicking in)

### Accessibility

- Search field: `aria-label="Search customer groups"`, `role="searchbox"`
- Table: `<Table aria-label="Customer groups table">`
- Row chevron button: `aria-label={`View ${row.name} group`}`
- "+ New Group" button: `aria-label="Create new customer group"`
- Focus: after modal closes (save or cancel), focus returns to the "+ New Group" button via `autoFocusAfterClose` on the `Dialog` or manual `ref.focus()` callback.

---

## Screen 2 — Group Create / Edit Modal

**File**: `sections/customer-groups/group-create-edit-modal.tsx`

### ASCII Wireframe

```
+----------------------------------------+
| Dialog (maxWidth="sm", fullWidth)       |
|  DialogTitle                            |
|  "New Customer Group" / "Edit Group"    |
|  [x] close icon                         |
+----------------------------------------+
|  DialogContent                          |
|  Form                                   |
|                                         |
|  Group Name *                           |
|  [______________________________]       |
|  helper: "Max 60 characters (12/60)"    |
|                                         |
|  Description  (optional)               |
|  [______________________________]       |
|  [______________________________]       |
|  helper: "Optional — max 280 chars"     |
|                                         |
+----------------------------------------+
|  DialogActions                          |
|  [Cancel]           [Save Group]        |
+----------------------------------------+
```

### Component Tree

```
GroupCreateEditModal
  Dialog[fullWidth, maxWidth="sm", open, onClose]
    DialogTitle
      Stack[direction=row, justifyContent=space-between, alignItems=center]
        Typography[variant="h6"]  "New Customer Group" | "Edit Group"
        IconButton[onClick=onClose]
          Iconify[icon="mingcute:close-line"]
    DialogContent[sx={{pt:1}}]
      Form[methods, onSubmit]
        Stack[spacing=2.5, sx={{py:1}}]
          Field.Text
            name="name"
            label="Group Name"
            required
            inputProps={{maxLength:60}}
            helperText={`${watchName.length}/60`}   ← character counter
          Field.Text
            name="description"
            label="Description"
            multiline
            minRows={3}
            inputProps={{maxLength:280}}
            helperText="Optional · max 280 characters"
    DialogActions
      Button[variant="outlined", onClick=onClose]  "Cancel"
      LoadingButton[type="submit", variant="contained", loading=isSubmitting]
        "Save Group"
```

### Zod Schema

```typescript
const schema = zod.object({
  name: zod
    .string({ required_error: 'Group name is required' })
    .min(1, 'Group name is required')
    .max(60, 'Max 60 characters'),
  description: zod.string().max(280, 'Max 280 characters').optional(),
});
```

### States

| State | Render |
|---|---|
| Initial (create) | Empty fields; "Save Group" button enabled |
| Initial (edit) | Fields pre-filled from `currentGroup` prop |
| Submitting | `LoadingButton` shows spinner; fields disabled |
| Name taken (409 `CUSTOMER_GROUP_NAME_TAKEN`) | Inline error on name field via `setError('name', {message:'A group with this name already exists'})` |
| Success | `toast.success("Group created")` / `"Group updated"` + modal closes |
| Network error | `toast.error(error.message)` + modal stays open |

### Interactions

- Name field: real-time character counter in helper text (`"X/60"`).
- Pressing Enter in the name field focuses the description field.
- Pressing Escape closes the modal (MUI Dialog default; verify `disableEscapeKeyDown` is false).
- Cancel button closes without saving; unsaved changes are discarded.

### Data Binding

| Field | DTO field on save |
|---|---|
| Name | `SparkCreateCustomerGroupDto.name` / `SparkUpdateCustomerGroupDto.name` |
| Description | `SparkCreateCustomerGroupDto.description` / `SparkUpdateCustomerGroupDto.description` |

**API (create)**: `POST /customer-groups` — body: `SparkCreateCustomerGroupDto`
**API (edit)**: `PATCH /customer-groups/:id` — body: `SparkUpdateCustomerGroupDto`

### PRD AC Mapping

- US-1 AC-1 (name required 1-60, description optional ≤280)
- US-1 AC-2 (duplicate name → validation error before creation — inline field error)
- US-1 AC-3 (empty group allowed — no member requirement at save time)

### Accessibility

- Dialog role: `role="dialog"`, `aria-labelledby="group-dialog-title"`, `aria-modal="true"`.
- On open: focus moves to the name input (`autoFocus` prop on the name `Field.Text`).
- On close: focus returns to the triggering element (the "+ New Group" button or the edit icon that opened it).
- Error messages: associated with fields via `aria-describedby` on the input and `id` on the `FormHelperText`.
- Keyboard: Tab cycles through Name → Description → Cancel → Save Group; Shift+Tab reverses.

---

## Screen 3 — Group Detail View

**File**: `sections/customer-groups/view/customer-group-detail-view.tsx`

### ASCII Wireframe

```
+------------------------------------------------------------------+
| DashboardContent                                                 |
|  CustomBreadcrumbs                                               |
|  heading: "Compound Residents"   (group name)                    |
|  links: [Dashboard > Customer Groups > Compound Residents]       |
|  action: [Edit Group]  (Button, variant=outlined)                |
+------------------------------------------------------------------+
|  Tabs  (sx={{ mb: {xs:3, md:5} }})                              |
|  [Members]  [Import]  [Settings]                                 |
+------------------------------------------------------------------+
|  <tab panel — see 3a, 3b, 3c below>                              |
+------------------------------------------------------------------+
```

### Component Tree (shell)

```
CustomerGroupDetailView
  DashboardContent
    CustomBreadcrumbs
      heading={group.name}
      links=[
        {name:"Dashboard", href:paths.dashboard.root},
        {name:"Customer Groups", href:paths.customerGroups.root},
        {name:group.name}
      ]
      action={
        PermissionGuard[CustomerGroupPermission.edit]
          Button[variant="outlined", startIcon=<Iconify icon="solar:pen-bold">]
            "Edit Group"   → opens GroupCreateEditModal with currentGroup prop
      }
    Tabs[value=currentTab, onChange=handleChangeTab, sx={{mb:{xs:3,md:5}}}]
      Tab[value="members", label="Members", icon=<Iconify icon="solar:users-group-rounded-bold" width=24>]
      Tab[value="import",  label="Import",  icon=<Iconify icon="solar:upload-bold" width=24>]
      Tab[value="settings",label="Settings",icon=<Iconify icon="solar:settings-bold" width=24>]
    {currentTab === "members"  && <CustomerGroupMembersTab groupId={id}>}
    {currentTab === "import"   && <CustomerGroupImportTab groupId={id}>}
    {currentTab === "settings" && <CustomerGroupSettingsTab groupId={id} group={group}>}
```

---

### Screen 3a — Members Tab

**File**: `sections/customer-groups/customer-group-members-tab.tsx`

#### ASCII Wireframe

```
+------------------------------------------------------------------+
|  Card                                                            |
|  +------------------------------------------------------------+  |
|  | Stack[direction=row, justifyContent=space-between]         |  |
|  | [  Search by name or phone  ][_________________]           |  |
|  |                              [+ Add Member]                |  |
|  +------------------------------------------------------------+  |
|  | Scrollbar > Table (minWidth: 640)                          |  |
|  | +--------------+---------------------+----------+--------+ |  |
|  | | Name         | Phone               | Added    | [del]  | |  |
|  | +--------------+---------------------+----------+--------+ |  |
|  | | Ahmed Karim  | +20 10 1234 5678     | 2 Jun    | [x]    | |  |
|  | | ...          | ...                 | ...      | ...    | |  |
|  | +--------------+---------------------+----------+--------+ |  |
|  |                                                            |  |
|  | TablePaginationCustom                                      |  |
|  +------------------------------------------------------------+  |
+------------------------------------------------------------------+
```

**Empty state (zero members)**:

```
+------------------------------------------------------------------+
|  Card                                                            |
|  [same toolbar with search + Add Member]                         |
|  EmptyContent                                                    |
|    title="No members yet"                                        |
|    description="Add members manually or use the Import tab to    |
|                 upload an Excel file."                           |
|    imgUrl="/assets/illustrations/illustration-empty-content.svg" |
+------------------------------------------------------------------+
```

#### Component Tree

```
CustomerGroupMembersTab
  Card
    Stack[direction="row", p=2.5, gap=2, flexWrap="wrap"]
      TextField
        name="memberSearch"
        placeholder="Search by name or phone"
        InputProps={startAdornment:<Iconify icon="eva:search-fill">}
        sx={{flex:1, minWidth:200}}
      PermissionGuard[CustomerGroupPermission.editMembers]
        Button
          variant="contained"
          startIcon={<Iconify icon="mingcute:add-line">}
          onClick={addMemberDialog.onTrue}
          "Add Member"
    Scrollbar
      Table[size="medium", sx={{minWidth:640}}]
        TableHeadCustom[headLabel=MEMBER_TABLE_HEAD]
        TableBody
          [loading] → TableSkeleton rows
          [data]    → members.map → CustomerGroupMemberTableRow
          TableEmptyRows
          [empty && no search] → EmptyContent["No members yet"]
          [empty && searching] → TableNoData
    TablePaginationCustom

  // Add Member dialog (inline in same file, controlled by addMemberDialog boolean)
  AddMemberDialog
    Dialog[fullWidth, maxWidth="sm"]
      DialogTitle "Add Member"
      DialogContent
        Autocomplete
          options={searchResults}    ← from GET /customer-groups/members/search?q=X
          loading={searchLoading}
          getOptionLabel={user => `${firstName} ${lastName} · ${phoneNumber}`}
          renderOption={ListItemText primary+secondary}
          onInputChange → debounced search
          onChange → setSelectedUser
      DialogActions
        Button "Cancel"
        LoadingButton "Add to Group"  ← POST /customer-groups/:id/members
```

**MEMBER_TABLE_HEAD**:

| id | label | width |
|---|---|---|
| `name` | `"Name"` | — (flex) |
| `phoneNumber` | `"Phone"` | 200 |
| `addedAt` | `"Added"` | 140 |
| `""` | `""` | 64 (delete action) |

**CustomerGroupMemberTableRow** renders:

- Name: `Typography variant="subtitle2"` — `"${firstName} ${lastName}"` (fallback `"—"` if both null)
- Phone: `Typography variant="body2" color="text.secondary"` — formatted E.164 or `"—"`
- Added: `fDate(addedAt)`
- Delete: `IconButton` with `<Iconify icon="solar:trash-bin-trash-bold" color="error.main">` — opens an inline `ConfirmDialog` with message: `"Remove ${name} from this group? This does not remove them from the tenant."` Action button: `Button[color="error"]` "Remove"

#### States

| State | Render |
|---|---|
| Loading | `TableSkeleton` (5 rows) |
| Empty — no members, no search | `EmptyContent` with illustration + CTA text above |
| Empty — search yielded nothing | `TableNoData` |
| Data | Table rows, paginated |
| Remove pending | `IconButton` disabled + spinner inside the row during DELETE in-flight |

#### Data Binding

| UI | DTO |
|---|---|
| Name | `SparkCustomerGroupMemberDto.firstName` + `.lastName` |
| Phone | `SparkCustomerGroupMemberDto.phoneNumber` |
| Added | `SparkCustomerGroupMemberDto.addedAt` |
| Remove action | `DELETE /customer-groups/:groupId/members/:userId` |
| Add action | `POST /customer-groups/:groupId/members` body `{userId}` |
| Search source | `GET /customer-groups/:groupId/members/search?q=X` (reuses tenant user search) |

**API**: `GET /customer-groups/:id/members?page=N&limit=10&search=<text>` — returns `SparkCustomerGroupMemberDto[]` paginated.

#### PRD AC Mapping

- US-3 AC-1 (search tenant users by name/phone → add to group)
- US-3 AC-2 (remove member; `TenantUser` join stays — copy text on confirm dialog)
- US-3 AC-3 (paginated, searchable, default sort most-recently-added)

#### Accessibility

- Add Member button: `aria-label="Add member to group"`.
- Search field: `aria-label="Search members"`.
- Delete button per row: `aria-label={`Remove ${firstName} ${lastName} from group`}`.
- Dialog: `aria-labelledby`, focus trap, focus returns to the triggering row's delete icon on close.

---

### Screen 3b — Import Tab

**File**: `sections/customer-groups/customer-group-import-tab.tsx`

This tab contains the full Excel import flow as inline sub-states. There is no separate "import page" — the tab itself progresses through states.

#### ASCII Wireframe — Idle state (no active job)

```
+------------------------------------------------------------------+
|  Stack[spacing=3]                                                |
|                                                                  |
|  Card                                                            |
|  +---------------------------------------------------------+    |
|  | CardHeader title="Import Members from Excel"            |    |
|  |            subheader="Upload an Excel file with         |    |
|  |            Mobile, First Name, Last Name columns."      |    |
|  |                                                         |    |
|  | [Download sample Excel]  (Button, variant=outlined,     |    |
|  |   startIcon=<Iconify icon="solar:download-bold">)       |    |
|  |                                                         |    |
|  | Upload dropzone (Upload component, accept=.xlsx)        |    |
|  | +-----------------------------------------------------+ |    |
|  | |          [cloud-upload icon]                        | |    |
|  | |   Drop .xlsx file here, or click to browse          | |    |
|  | |   Max 10,000 rows · Excel (.xlsx) only              | |    |
|  | +-----------------------------------------------------+ |    |
|  |                                                         |    |
|  | [file selected preview: filename + size]                |    |
|  |                                                         |    |
|  | [Upload & Import]  (LoadingButton, disabled until file) |    |
|  +---------------------------------------------------------+    |
+------------------------------------------------------------------+
```

#### ASCII Wireframe — Processing state

```
+------------------------------------------------------------------+
|  Card                                                            |
|  +---------------------------------------------------------+    |
|  | CardHeader title="Import in Progress"                   |    |
|  |   subheader="Processing 412 / 1,000 rows..."            |    |
|  |                                                         |    |
|  | LinearProgress[variant=determinate, value=41]           |    |
|  |   (value = rowsProcessed / rowsTotal * 100)             |    |
|  | Typography[variant=caption, color=text.secondary]       |    |
|  |   "Row 412 of 1,000 — this may take a few minutes."     |    |
|  +---------------------------------------------------------+    |
+------------------------------------------------------------------+
```

#### ASCII Wireframe — Completed state

```
+------------------------------------------------------------------+
|  Card                                                            |
|  +---------------------------------------------------------+    |
|  | CardHeader title="Import Complete"                      |    |
|  |   action=[Download Result Excel]                        |    |
|  |                                                         |    |
|  | Stack[direction=row, spacing=2, flexWrap=wrap, py=2]    |    |
|  | +----------+ +----------+ +----------+ +----------+    |    |
|  | |312       | |588       | |67        | |29        |    |    |
|  | |Created   | |Attached  | |Already   | |Errors    |    |    |
|  | |(new user)| |(existing)| |member    | |          |    |    |
|  | +----------+ +----------+ +----------+ +----------+    |    |
|  |  (stat cards, each a Paper with colored top border)    |    |
|  |                                                         |    |
|  | [Import Another File]  (Button, variant=outlined)      |    |
|  +---------------------------------------------------------+    |
+------------------------------------------------------------------+
```

#### ASCII Wireframe — Failed state (file-level error)

```
+------------------------------------------------------------------+
|  Card                                                            |
|  +---------------------------------------------------------+    |
|  | Alert[severity="error"]                                 |    |
|  |   "Import failed: Invalid Excel headers. Expected       |    |
|  |    Mobile, First Name, Last Name."                      |    |
|  | [Try Again]  (Button, variant="outlined")               |    |
|  +---------------------------------------------------------+    |
+------------------------------------------------------------------+
```

#### Component Tree

```
CustomerGroupImportTab
  Stack[spacing=3]
    // --- Header card with template download ---
    Card
      Stack[p=3, spacing=2]
        Stack[direction=row, justifyContent=space-between, alignItems=flex-start]
          Box
            Typography[variant="h6"] "Import Members from Excel"
            Typography[variant="body2", color="text.secondary"]
              "Upload an .xlsx file with columns: Mobile, First Name, Last Name"
          Button
            variant="outlined"
            startIcon={<Iconify icon="solar:download-bold">}
            href="/customer-groups/import-template"   ← GET /customer-groups/import-template (download)
            download
            "Download Sample"

    // --- Upload card (shown when status = idle | null) ---
    {!activeJob && (
      Card
        Stack[p=3, spacing=2]
          Upload
            accept={{"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet":[".xlsx"]}}
            value={uploadedFile}
            onDrop={setUploadedFile}
            helperText="Max 10,000 rows · .xlsx only"
          LoadingButton
            disabled={!uploadedFile}
            loading={isUploading}
            onClick={handleUpload}    ← POST /customer-groups/:id/import
            variant="contained"
            "Upload & Import"
    )}

    // --- Progress card (status = queued | processing) ---
    {activeJob?.status === 'processing' || activeJob?.status === 'queued' && (
      Card
        Stack[p=3, spacing=2]
          Typography[variant="subtitle1"] "Import in Progress"
          LinearProgress
            variant={activeJob.rowsTotal ? "determinate" : "indeterminate"}
            value={(activeJob.rowsProcessed / activeJob.rowsTotal) * 100}
          Typography[variant="caption", color="text.secondary"]
            `Row ${activeJob.rowsProcessed} of ${activeJob.rowsTotal ?? '...'}`
    )}

    // --- Results card (status = completed) ---
    {activeJob?.status === 'completed' && (
      Card
        Stack[p=3, spacing=2]
          Stack[direction=row, justifyContent=space-between]
            Typography[variant="h6"] "Import Complete"
            Button
              startIcon={<Iconify icon="solar:download-bold">}
              href={activeJob.resultUrl}    ← SparkCustomerGroupImportStatusDto (resultUrl from job)
              download
              "Download Result Excel"
          ImportResultSummary[totals=activeJob.totals]   ← sub-component, 4 stat cards
          Button[variant="outlined", onClick={() => setActiveJob(null)}]
            "Import Another File"
    )}

    // --- Error card (status = failed) ---
    {activeJob?.status === 'failed' && (
      Card
        Stack[p=3, spacing=2]
          Alert[severity="error"]
            activeJob.errorMessage || "Import failed. Please check the file and try again."
          Button[variant="outlined", onClick={() => setActiveJob(null)}]
            "Try Again"
    )}
```

**ImportResultSummary sub-component**:

```
ImportResultSummary (props: totals: ISparkCustomerGroupImportTotalsDto)
  Grid[container, spacing=2]
    Grid[xs=6, sm=3]  ImportStatCard[value=totals.created_new,     label="Created",  sublabel="new users",  color="success"]
    Grid[xs=6, sm=3]  ImportStatCard[value=totals.attached_existing, label="Attached", sublabel="existing",   color="info"]
    Grid[xs=6, sm=3]  ImportStatCard[value=totals.already_member,  label="Already",   sublabel="members",    color="default"]
    Grid[xs=6, sm=3]  ImportStatCard[value=totals.error,           label="Errors",    sublabel="skipped",    color="error"]
```

Each `ImportStatCard` is a `Paper[variant="outlined"]` with a 4px top border in the matching color, `Typography[variant="h4"]` for the count, and two `Typography[variant="caption"]` lines for label + sublabel.

**Polling logic**: After a successful `POST /customer-groups/:id/import` returns `{jobId, status:"queued"}`, the tab starts polling `GET /customer-groups/:id/imports/:jobId` every 3 seconds via a `useEffect` + `setInterval` (or SWR `refreshInterval`). Polling stops when `status` reaches `completed` or `failed`. Mount state cleans up the interval.

If the tab is re-opened while a job is in-flight (e.g. user navigated away and back), the view re-fetches the latest import job on mount via `GET /customer-groups/:id/imports` (latest job endpoint — confirm with backend) and resumes the correct state.

#### States

| State | Render |
|---|---|
| Idle | Upload card |
| File selected | Upload card with file preview (filename + size) + active "Upload & Import" |
| Uploading | `LoadingButton` spinner; Upload component disabled |
| Queued | Progress card, `LinearProgress[variant="indeterminate"]` |
| Processing | Progress card, `LinearProgress[variant="determinate"]`, row counter |
| Completed | Results card with 4 stat tiles + "Download Result Excel" |
| Failed | Error card with the `errorMessage` from the audit row |

#### Data Binding

| UI | DTO field |
|---|---|
| Progress bar value | `SparkCustomerGroupImportStatusDto.rowsProcessed / rowsTotal` |
| Row counter | `rowsProcessed`, `rowsTotal` |
| Created count | `totals.created_new` |
| Attached count | `totals.attached_existing` |
| Already member count | `totals.already_member` |
| Error count | `totals.error` |
| Download result button | `resultUrl` (signed S3 URL from the polling response) |
| File-level error | `errorMessage` |

**API calls**:

- `GET /customer-groups/import-template` — download (anchor tag, `download` attribute)
- `POST /customer-groups/:id/import` — multipart, returns `{jobId, status}`
- `GET /customer-groups/:id/imports/:jobId` — poll, returns `SparkCustomerGroupImportStatusDto`
- `GET /customer-groups/:id/imports/:jobId/result.xlsx` — redirect to signed URL

#### PRD AC Mapping

- US-2 AC-1 (template download)
- US-2 AC-3 (phone normalised, rows skipped with per-row error — visible in downloaded result)
- US-2 AC-5 (async Bull job — progress indicator)
- US-2 AC-6 (result summary: 4 outcome buckets + downloadable result xlsx)
- US-2 AC-7 (re-import idempotent — UI just shows totals; no warning needed for already_member rows)
- US-2 AC-9 (10k-row cap — API returns `400 IMPORT_TOO_LARGE`; map to toast.error "File exceeds 10,000 row limit")

#### Accessibility

- `Upload` dropzone: `role="button"`, `aria-label="Upload Excel file"`, `aria-describedby` → helper text.
- Progress bar: `aria-label="Import progress"`, `aria-valuenow={rowsProcessed}`, `aria-valuemax={rowsTotal}`.
- Stat cards: each `Paper` has `role="status"` + `aria-label={`${count} ${label}`}`.
- Result download link: `aria-label="Download import result Excel file"`.

---

### Screen 3c — Settings Tab

**File**: `sections/customer-groups/customer-group-settings-tab.tsx`

#### ASCII Wireframe

```
+------------------------------------------------------------------+
|  Stack[spacing=3, maxWidth=560]                                  |
|                                                                  |
|  Card                                                            |
|  +---------------------------------------------------------+    |
|  | CardHeader title="Danger Zone"                          |    |
|  |   sx={{ color: 'error.main' }}                         |    |
|  |                                                         |    |
|  | Stack[p=3, direction=row, justifyContent=space-between, |    |
|  |        alignItems=center]                               |    |
|  |   Box                                                   |    |
|  |     Typography[variant="subtitle1"] "Delete this group" |    |
|  |     Typography[variant="body2", color="text.secondary"] |    |
|  |       "Permanently removes this group. Spaces           |    |
|  |        restricted to this group will revert to public   |    |
|  |        if no other groups are attached."                |    |
|  |   Button[color="error", variant="outlined"]             |    |
|  |     "Delete Group"                                      |    |
|  +---------------------------------------------------------+    |
+------------------------------------------------------------------+
```

#### Component Tree

```
CustomerGroupSettingsTab
  Stack[spacing=3, sx={{maxWidth:560}}]
    Card
      Stack[p=3, spacing=2]
        Stack[direction="row", justifyContent="space-between", alignItems="center"]
          Box
            Typography[variant="subtitle1"] "Delete this group"
            Typography[variant="body2", color="text.secondary"]
              "Permanently removes this group. Any spaces restricted only to this group
               will revert to Public access automatically."
          PermissionGuard[CustomerGroupPermission.delete]
            Button
              color="error"
              variant="outlined"
              startIcon={<Iconify icon="solar:trash-bin-trash-bold">}
              onClick={deleteDialog.onTrue}
              "Delete Group"

    SoftDeleteConfirmDialog          ← spec below (Component Spec 1)
      open={deleteDialog.value}
      groupName={group.name}
      affectedSpacesCount={affectedSpacesCount}    ← fetched from group detail
      onClose={deleteDialog.onFalse}
      onConfirm={handleSoftDelete}   ← DELETE /customer-groups/:id → success → router.push(paths.customerGroups.root)
```

#### States

| State | Render |
|---|---|
| Idle | Settings card with delete button |
| Dialog open | `SoftDeleteConfirmDialog` overlaid |
| Deleting | LoadingButton spinner inside dialog action |
| Success | `toast.success("Group deleted. Affected spaces reverted to Public.")` + navigate to list |
| Error | `toast.error(error.message)` + dialog stays open |

#### PRD AC Mapping

- US-7 AC-1 (soft-delete disappears from admin UI — navigate away on success)
- US-7 AC-2 (auto-revert message in the confirmation dialog warns admin before delete)

#### Accessibility

- "Delete Group" button: `aria-label="Delete customer group"`.
- Dialog: see Component Spec 1 below.

---

## Screen 4 — Excel Import Flow (standalone re-statement)

The import flow lives entirely within Screen 3b (Import tab). The flow states are:

```
[Idle] → [File selected] → [Uploading] → [Queued]
    → [Processing (polling)] → [Completed | Failed]
```

The four outcome buckets in the result summary are (`SparkCustomerGroupImportStatusDto.totals`):

| Bucket | Label | Color |
|---|---|---|
| `created_new` | "Created" / "new users" | `success` |
| `attached_existing` | "Attached" / "existing users" | `info` |
| `already_member` | "Already" / "members" | `default` |
| `error` | "Errors" / "skipped" | `error` |

The "Download Result Excel" button renders as an anchor (`<a>` with `download`) pointing at `resultUrl` from the polling response. It appears only when `status === 'completed'`.

No separate page is needed. The entire flow is inline within the tabbed detail view.

---

## Screen 5 — Space Edit — Access Section

**File**: Modify existing `sections/space/components/` — new file `space-access-form.tsx`
**Also modify**: `sections/space/space-new-edit.tsx` — add the Access section between "Advanced Settings" and the submit row.

### ASCII Wireframe

```
-- (existing sections above: Details, Properties, Availability, Advanced Settings) --

+-- Grid[md=4] (label column, mdUp only) ---+  +-- Grid[xs=12, md=8] --+
| Typography[variant="h6"] "Access"         |  | Card                  |
| Typography[variant="body2"] "Control who  |  |  Stack[p=3, spacing=3]|
|  can see and book this space."            |  |                       |
+-------------------------------------------+  | Access Mode           |
                                               | ToggleButtonGroup      |
                                               | [Public] [Restricted]  |
                                               |                        |
                                               | {mode=Restricted &&    |
                                               |  Field.Autocomplete    |
                                               |  label="Groups"        |
                                               |  multiple              |
                                               |  options=tenantGroups  |
                                               |  error if empty }      |
                                               +------------------------+

-- (submit row below) --
```

### Component Tree

```
SpaceAccessForm  (new component, used in SpaceNewEdit Grid section)
  Card[sx={{height:'100%'}}]
    Stack[p=3, spacing=3]
      Box
        Typography[variant="subtitle2", sx={{mb:0.5}}] "Access Mode"
        ToggleButtonGroup
          value={watchAccessMode}         ← "public" | "restricted"
          exclusive
          onChange={(_,v) => v && setValue("accessMode", v)}
          sx={{mt:1}}
          ToggleButton[value="public"]
            Iconify[icon="solar:global-bold", sx={{mr:1}}]
            "Public"
          ToggleButton[value="restricted"]
            Iconify[icon="solar:lock-bold", sx={{mr:1}}]
            "Restricted to groups"

      {watchAccessMode === 'restricted' && (
        Field.Autocomplete
          name="customerGroups"
          label="Allowed Groups"
          multiple
          disableCloseOnSelect
          required
          options={tenantGroups}           ← from useGetCustomerGroups() SWR hook
          loading={groupsLoading}
          getOptionLabel={g => g.name}
          isOptionEqualToValue={(o,v) => o.id === v.id}
          noOptionsText={groupsLoading ? "Loading..." : "No groups found"}
          renderTags={(selected, getTagProps) =>
            selected.map((g, i) =>
              <Chip {...getTagProps({index:i})} key={g.id} label={g.name} size="small" color="info" variant="soft" />
            )
          }
          renderOption={(props, g) => <li {...props} key={g.id}>{g.name}</li>}
          helperText={errors.customerGroups?.message}  ← shown when empty+restricted
      )}
```

**Zod schema addition** (added to `BaseSchema` in `space-new-edit.tsx`):

```typescript
accessMode: zod.enum(['public', 'restricted']).default('public'),
customerGroups: zod.array(zod.object({ id: zod.number(), name: zod.string() })).optional(),
```

**Refine** added at the schema level:

```typescript
.refine(
  (data) => data.accessMode === 'public' || (data.customerGroups?.length ?? 0) > 0,
  {
    path: ['customerGroups'],
    message: 'At least one group is required for Restricted access',
  }
)
```

**Default values** (added to `getSpaceDefaultValue`):

- `accessMode`: `currentSpace?.accessMode ?? 'public'`
- `customerGroups`: `currentSpace?.customerGroups ?? []`

**On submit**: `convertFormValuesToUpdateSpaceDto` extended to include:

```typescript
accessMode: data.accessMode,
customerGroupIds: data.customerGroups?.map(g => g.id) ?? [],
```

**API**: `PATCH /spaces/:id/access` body `{accessMode, customerGroupIds}` — separate from the main space save OR integrated into the existing PATCH. Confirm with backend: the tech design specifies a dedicated endpoint `PATCH /spaces/:id/access`; the frontend should call it as a second request after the main space save if they are separate endpoints, or the backend should accept `accessMode` + `customerGroupIds` on the main PATCH. The frontend should prefer the simpler path; raise with backend if ambiguous.

### States

| State | Render |
|---|---|
| `accessMode = 'public'` | Toggle shows "Public" active; no group selector visible |
| `accessMode = 'restricted'` (groups selected) | Toggle shows "Restricted" active; group chips visible |
| `accessMode = 'restricted'` (no groups, form submitted) | Group selector shows red helper text "At least one group is required"; Save button disabled by zod refine |
| Groups loading | `Field.Autocomplete` shows `loading` spinner in the dropdown |
| Groups fetch error | `toast.error("Failed to load groups")` + autocomplete shows empty options |

### Interactions

- Switching from "Restricted" to "Public" via the toggle clears the selected groups from the form value (to prevent stale group state on re-toggle).
- Switching from "Public" to "Restricted" on an existing space that previously had groups: re-populate from the existing `space.customerGroups`.
- The Save button is disabled by the Zod refine when `restricted + zero groups`.
- Error `400 RESTRICTED_REQUIRES_GROUPS` from the API (defence-in-depth): map to `setError('customerGroups', {message: 'At least one group is required'})`.

### Data Binding

| UI | API field |
|---|---|
| Access mode toggle | `SparkSpaceAccessDto.accessMode` (`'public'` or `'restricted'`) |
| Group multi-select | `SparkSpaceAccessDto.customerGroupIds` (array of group `id`s) |
| Group chips display | `SparkCustomerGroupDto.name` from tenant group list |

**API (groups list)**: `GET /customer-groups?limit=100` — all active tenant groups (no pagination for the selector; assume ≤100 groups per tenant for V1; add server-side search if needed later).

### PRD AC Mapping

- US-4 AC-1 (toggle: Public / Restricted)
- US-4 AC-2 (multi-select one or more groups; OR semantics handled server-side)
- US-4 AC-3 (OR semantics — no UI action needed; purely server-side)
- US-4 AC-4 (cannot save Restricted with zero groups — Zod refine + disabled Save)
- US-4 AC-5 (switching Public→Restricted is immediate on save — no warning needed)
- US-4 AC-6 (switching Restricted→Public is immediate on save — no warning needed)

### Accessibility

- `ToggleButtonGroup`: `aria-label="Space access mode"`.
- Each `ToggleButton`: `aria-pressed` managed by MUI automatically.
- Group autocomplete: `aria-label="Select allowed groups"`, `aria-required="true"` when mode is restricted.
- Inline error: `aria-describedby` links the helper text to the autocomplete input.
- Keyboard: Toggle buttons respond to Space/Enter; Tab moves to the group selector when visible.

---

## Component Spec 1 — Soft-Delete Confirmation Dialog

**File**: `sections/customer-groups/soft-delete-confirm-dialog.tsx`

### ASCII Wireframe

```
+------------------------------------------+
| Dialog (maxWidth="xs", fullWidth)         |
|  DialogTitle                              |
|  "Delete Customer Group"                  |
|  [x]                                      |
+------------------------------------------+
|  DialogContent                            |
|                                           |
|  Alert[severity="warning"]               |
|    "This action cannot be undone."        |
|    "2 space(s) will revert to Public     |
|     access automatically."               |
|                                           |
|  Typography[variant="body2", mb=1]        |
|    "To confirm, type the group name below:|
|    "Compound Residents""                  |
|                                           |
|  TextField                                |
|    label="Type group name to confirm"     |
|    value={confirmText}                    |
|    onChange → setConfirmText              |
|    error={confirmText && confirmText !== groupName} |
|                                           |
+------------------------------------------+
|  DialogActions                            |
|  [Cancel]   [Delete Group]                |
|             (disabled until confirmText   |
|              matches groupName exactly)   |
+------------------------------------------+
```

### Component Tree

```
SoftDeleteConfirmDialog
  Props: { open, groupName, affectedSpacesCount, onClose, onConfirm, isDeleting }

  Dialog[fullWidth, maxWidth="xs", open, onClose]
    DialogTitle
      Stack[direction=row, justifyContent=space-between, alignItems=center]
        "Delete Customer Group"
        IconButton[onClick=onClose]  Iconify["mingcute:close-line"]
    DialogContent[sx={{pt:2}}]
      Stack[spacing=2.5]
        Alert[severity="warning"]
          Typography[variant="body2"]
            "This action cannot be undone."
          {affectedSpacesCount > 0 && (
            Typography[variant="body2", sx={{mt:0.5}}]
              `${affectedSpacesCount} space(s) currently restricted to this group will
               automatically revert to Public access.`
          )}
        Typography[variant="body2"]
          `To confirm, type the group name: `
          Typography[component="span", variant="body2", fontWeight="bold"]
            `"${groupName}"`
        TextField
          fullWidth
          label="Confirm group name"
          value={confirmText}
          onChange={e => setConfirmText(e.target.value)}
          error={!!confirmText && confirmText !== groupName}
          helperText={confirmText && confirmText !== groupName ? "Name does not match" : " "}
          inputProps={{ "aria-label": "Type group name to confirm deletion" }}
    DialogActions
      Button[variant="outlined", onClick=onClose] "Cancel"
      LoadingButton
        variant="contained"
        color="error"
        loading={isDeleting}
        disabled={confirmText !== groupName}
        onClick={onConfirm}
        "Delete Group"
```

### States

| State | Render |
|---|---|
| Dialog open, empty confirm field | Delete button disabled |
| Typing, partial match | Red helper text "Name does not match" |
| Exact match | Delete button enabled (red `color="error"`) |
| Deleting in-flight | `LoadingButton` spinner, Cancel disabled |

### Accessibility

- `aria-labelledby="soft-delete-dialog-title"`, `aria-describedby="soft-delete-dialog-description"`.
- On open: focus moves to the confirmation `TextField`.
- Delete button: `aria-disabled="true"` when text doesn't match (in addition to MUI `disabled`).
- Alert: `role="alert"` (MUI Alert default).

---

## Component Spec 2 — Auto-Revert Banner

**File**: `sections/customer-groups/auto-revert-banner.tsx`

This component surfaces the consequence of a group soft-delete: one or more spaces were reverted to Public. It has two display surfaces depending on timing:

**Surface A — Toast (immediate, fires right after delete succeeds)**

On successful `DELETE /customer-groups/:id` response, if the response body includes `revertedSpaces` (an array of space names/IDs that were reverted):

```typescript
if (result.revertedSpaces?.length) {
  toast.warning(
    `${result.revertedSpaces.length} space(s) reverted to Public access: ${result.revertedSpaces.map(s => s.name).join(', ')}`,
    { autoHideDuration: 8000 }
  );
}
```

If the backend does not return `revertedSpaces` in the delete response (confirm with backend), fall back to a generic message: `"Group deleted. Any spaces restricted only to this group were reverted to Public access."`

**Surface B — Persistent in-app banner on Spaces list (for async or cross-session discovery)**

When the tenant admin navigates to the Spaces list after a group was auto-reverted, show a dismissible `Alert` at the top of the Spaces list page if there are spaces in `accessMode='public'` whose `updatedAt` is within the last 24 hours and whose previous mode was `restricted` (this requires a backend signal — confirm with backend whether the space detail DTO includes a `wasAutoReverted: boolean` or `lastAutoRevertAt: Date | null` field).

If backend does not expose this signal in V1, implement Surface A (toast) only and defer Surface B to a follow-up.

### Component Tree (Surface B, if signal available)

```
AutoRevertBanner  (placed at top of spaces list, above the Card)
  Props: { revertedSpaces: SparkSpaceDto[] }

  Collapse[in={revertedSpaces.length > 0}]
    Alert
      severity="warning"
      onClose={() => dismissBanner()}   ← persisted to localStorage with a timestamp key
      icon={<Iconify icon="solar:info-circle-bold">}
      action={
        Button[variant="text", color="warning", onClick=navigateToSpaces]
          "View spaces"
      }
      `${revertedSpaces.length} space(s) were automatically set to Public access after a
       customer group was deleted.`
```

### PRD AC Mapping

- US-7 AC-2 (tenant admin notified when space reverts to Public — toast is the V1 minimum; persistent banner is enhancement)

### Accessibility

- `Alert` with `role="alert"` and `aria-live="polite"` for the persistent banner.
- Toast: `aria-live="assertive"` (via the existing snackbar component).
- Dismiss button on the persistent banner: `aria-label="Dismiss auto-revert warning"`.

---

## Routing & Navigation

New routes to add to `src/routes/paths.ts`:

```typescript
customerGroups: {
  root: '/customer-groups',
  detail: (id: number | string) => `/customer-groups/${id}`,
  // tabs are hash-based or handled via currentTab state — no separate route per tab
},
```

New sidebar entry in the navigation config (exact file TBD — check `src/layouts/dashboard/nav-config.ts` or equivalent):

```typescript
{
  title: 'Customer Groups',
  path: paths.customerGroups.root,
  icon: ICONS.users,    // reuse the users icon: 'solar:users-group-rounded-bold'
  permissions: [CustomerGroupPermission.list],
}
```

Position: under the existing "Customers" menu item in the sidebar.

---

## API Hook Conventions

Follow the existing SWR hook pattern from `src/api/customers.ts`. New hooks to create at `src/api/customer-groups.ts`:

| Hook | Endpoint | Used by |
|---|---|---|
| `useGetCustomerGroups(filters, page, limit)` | `GET /customer-groups` | List view, Space Access selector |
| `useGetCustomerGroup(id)` | `GET /customer-groups/:id` | Detail view header |
| `useGetCustomerGroupMembers(id, filters, page, limit)` | `GET /customer-groups/:id/members` | Members tab |
| `useGetImportStatus(groupId, jobId)` | `GET /customer-groups/:id/imports/:jobId` | Import tab polling |
| `createCustomerGroup(dto)` | `POST /customer-groups` | Create modal |
| `updateCustomerGroup(id, dto)` | `PATCH /customer-groups/:id` | Edit modal |
| `deleteCustomerGroup(id)` | `DELETE /customer-groups/:id` | Settings tab |
| `addGroupMember(groupId, userId)` | `POST /customer-groups/:id/members` | Members tab add dialog |
| `removeGroupMember(groupId, userId)` | `DELETE /customer-groups/:id/members/:userId` | Members tab row delete |
| `uploadGroupImport(groupId, file)` | `POST /customer-groups/:id/import` (multipart) | Import tab |
| `updateSpaceAccess(spaceId, dto)` | `PATCH /spaces/:id/access` | Space edit form |

---

## Out of Scope

- Mobile / customer-web screens for US-5 / US-6 (different repos).
- Super-admin cross-tenant group view.
- Time-window-scoped access (V2).
- Any screen beyond US-1..US-7 of the customer-groups epic.
- Invite / notification flows on user auto-creation during import (V2, per PRD Non-Goals).

---

## Glossary

| Term | Definition |
|---|---|
| `DashboardContent` | The standard MUI layout wrapper for all tenant-admin pages. Provides consistent padding and max-width. Located at `src/layouts/dashboard`. |
| `CustomBreadcrumbs` | The app's standard page header component. Accepts `heading`, `links`, and `action` props. Enforced on every view per `CLAUDE.md`. |
| `Iconify` | The app's icon component. All icons use icon-set strings (e.g. `"solar:users-group-rounded-bold"`). Never use raw SVG. |
| `useBoolean` | Minimals hook for toggle state (`value`, `onTrue`, `onFalse`). Controls dialogs, confirms. |
| `useTable` | Minimals hook that owns `dense`, `order`, `orderBy`, `rowsPerPage`, `onChangePage`, etc. |
| `TableSkeleton` | Shimmer-skeleton row for loading state — matches the existing Customer/Location table pattern. |
| `EmptyContent` | Full-height empty state with illustration + title + description. Use when a list is genuinely empty (zero items, no active filter). |
| `TableNoData` | Compact "no results" row. Use when a search or filter yields zero results from a non-empty dataset. |
| `Field.Autocomplete` | RHF-integrated MUI Autocomplete from `src/components/hook-form/fields.tsx`. The only Autocomplete variant to use in forms — handles error display and value registration automatically. |
| `Label` | MUI Chip-style status badge from `src/components/label`. Use `variant="soft"` for counts and status. |
| `ConfirmDialog` | Standard two-button confirm dialog from `src/components/custom-dialog`. Used for simple yes/no confirmations. For name-confirm destructive actions, use `SoftDeleteConfirmDialog` (this spec). |
| `Upload` | Dropzone-backed file upload component from `src/components/upload`. Accepts MUI-style `accept` mime map. |
| `Scrollbar` | Custom scrollbar wrapper from `src/components/scrollbar`. Required around any overflow `<Table>`. |
| `CustomerGroupPermission` | New enum in `libs/role/src/lib/types/permission-type.type.ts`. Values: `list`, `add`, `edit`, `delete`, `editMembers`, `import`. Mirror the pattern of `LocationPermission`. |
| `accessMode` | Per-space enum: `'public'` (default, current behaviour) or `'restricted'` (member-only). Added to `SparkSpaceDto`. |
| `SparkCustomerGroupDto` | The primary response DTO for a customer group. Includes `id`, `name`, `description`, `memberCount` (nullable), `createdAt`, `updatedAt`. |
| `SparkCustomerGroupImportStatusDto` | Import job status DTO. Fields: `jobId`, `status`, `rowsTotal`, `rowsProcessed`, `totals` (four-bucket object), `errorMessage`, `resultUrl` (when completed). |
