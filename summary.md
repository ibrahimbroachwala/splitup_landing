# Splitzy — Project Summary (for AI Agents)

> This document is a **standalone** reference to the Splitzy codebase: architecture, data model, backend, every implemented feature, and the coding conventions the codebase actually follows today. It is written so an AI agent can pick up work — bug fixes or new features — without needing to open any other file first. Concrete class/file/table names are used throughout instead of vague descriptions; treat them as accurate as of this writing, but verify against the live file when making a change, since the app evolves.

---

## 1. Overview

**Splitzy** (package name `splitup`) is a Flutter expense-splitting mobile app (Android + iOS) — think "Splitwise": users create shared groups (trips, flatmates, etc.), add members, log shared expenses with flexible splitting, and the app computes who owes whom and suggests the minimal set of settlement payments.

Core tech stack:
- **Flutter** (Dart ≥3.2.3), Material 3 UI, managed via **FVM** (Flutter Version Management) — the SDK version is pinned in `.fvmrc` to the `stable` channel. Prefix all Flutter/Dart commands with `fvm` (e.g. `fvm flutter run`).
- **Riverpod 3** (`flutter_riverpod`) with **code generation** (`riverpod_annotation` + `riverpod_generator` + `build_runner`) — the only state-management mechanism used; `setState` is never used.
- **Supabase** (`supabase_flutter`) is the primary backend: Postgres database, Auth, Storage (group images), Realtime (a user-row subscription), and RPC/Edge Functions.
- **Firebase** is used **only** for platform services — specifically Firebase Cloud Messaging (push notifications). It is not the data backend.
- **RevenueCat** (`purchases_flutter` / `purchases_ui_flutter`) handles in-app purchases and renders the paywall UI.
- **PostHog** (`posthog_flutter`) is the analytics/product-telemetry backend, including session replay in release builds.
- **go_router** provides a single centralized router.
- Auth is **Google Sign-In and Sign in with Apple only** — there is no email/password flow.
- 10 languages are supported via Flutter's standard `.arb`/`gen-l10n` localization pipeline.

Current app version at time of writing: `1.3.8+71` (see `pubspec.yaml`).

---

## 2. Architecture & Layering

Splitzy uses a **flat, layer-first** structure (not feature-first/folder-per-feature). Dependency direction is `Presentation → Domain(entities) → Data(services)`; UI never imports Supabase/Firebase/RevenueCat SDK types directly.

```
lib/
├── entities/     # Plain Dart data classes (fromJson/toJson/copyWith). No Flutter/Supabase imports.
├── providers/    # Riverpod controllers/providers — state + orchestration. Flat, with a few feature subfolders
│   └── add_expense/   # Multi-file controller for the add/edit-expense flow (state, calculator, validator)
├── services/     # The ONLY place Supabase/Firebase/RevenueCat SDK calls are allowed to live
├── screens/      # One folder per feature/page, each with its own widgets/ subfolder for feature-local widgets
├── widgets/      # Reusable app-wide widgets (buttons, toasts, dialogs, etc.)
├── styles/       # Theme, colors, text styles, image/asset helpers (new files should use an `app_` prefix)
├── route/        # Centralized GoRouter config (router.dart) + custom page transitions (transitions.dart)
├── utils/        # Constants, extensions, misc helpers, plus utils/export_data/ (PDF/Excel export, non-Riverpod)
├── l10n/         # Source .arb files (10 languages)
├── gen/          # Generated AppLocalizations (from l10n/, via `flutter gen-l10n` — never hand-edit)
└── main.dart
```

Hard rules enforced by convention (and largely by lint, see §9):
- **Never** call Supabase/Firebase/RevenueCat SDKs directly from a screen or widget — go through `lib/services/` (e.g. `SupabaseApi`, `PaymentService`, `NotificationService`), which are exposed as Riverpod providers so they can be mocked/overridden in tests.
- **No `setState`** anywhere — all UI state flows through `@riverpod` providers/controllers.
- Entities stay pure Dart — no Flutter/Supabase/Firebase types, hand-written `fromJson`/`toJson`/`copyWith` (the codebase does **not** use `freezed`).
- No typed `Failure`/`AppException` hierarchy — error handling is ad hoc: `services/` wrap SDK calls in try/catch, log via `logError()`, and rethrow as a generic `Exception('Failed to ...: $e')`; controllers catch that and set `state = AsyncValue.error(e, StackTrace.current)`.
- Imports within `lib/` are **relative** (`../styles/colors.dart`), not `package:splitup/...` — enforced by the `prefer_relative_imports` lint rule.
- File names: `snake_case.dart`. Classes: `PascalCase`. Suffixes: `Entity`, `Model`, `Repository`/`RepositoryImpl`, `Provider`, `Service`.
- Money is always **integer cents**, never a raw `double`, in both the app and the database — divide by 100.0 only at display time.

There are two "instructions" documents at the repo root in addition to this one: `.github/copilot-instructions.md` (a fairly generic Clean-Architecture template, only partially accurate for this codebase — e.g. it implies a UseCase layer and generic example dependency versions that don't match reality) and `standard_code_guide.md` (an up-to-date, codebase-accurate conventions doc, together with `CLAUDE.md`). This `summary.md` reflects the accurate current state (matching `standard_code_guide.md`/`CLAUDE.md`), not the generic template. A further file, `copilot-instructions-firebase.md`, is an obsolete template for a different Firebase-primary stack and should be ignored entirely.

---

## 3. Data Model

### 3.1 Entities (`lib/entities/`)

All entities are plain, hand-written Dart classes (no `freezed`) with `fromJson`/`toJson` (or `toMap`/`fromMap`) and `copyWith`. There is no shared base entity class.

**`ExpenseGroup`** (`group.dart`) — a shared expense group ("trip", "flatmates", etc.):
- `id` (int?), `name`, `createdAt`, `admin` (uuid of the creator/owner), `imageUrl`, `currency` (code string, e.g. `"USD"`), `accessCode` (6-character join code), `isSynced` (local-only flag, not persisted).

**`Member`** (`member.dart`) — a person inside a group:
- `name`, `id` (String — either a real Supabase auth uid for a signed-in `AppUser`, or a locally generated uuid for a placeholder/non-app member added manually), `groupId` (int?).

**`Transaction`** (`transaction.dart`) — the central financial record, representing either an expense or a settlement:
- `id`, `groupId`, `title`, `description`, `amount` (int, cents), `paidBy` (uid — legacy single-payer field, still used as fallback), `paidTo` (uid, used for settlements), `shareType` (`'equally' | 'amount' | 'percentage' | 'portion'`), `shares` — `Map<String, Map<String, dynamic>>` keyed by member id → `{'name', 'share' (cents), optionally 'portion'}` — the source of truth for **who owes what**, `payers` — `Map<String, Map<String, dynamic>>?` keyed by member id → `{'name', 'amount' (cents)}` — the source of truth for **who paid what**, supporting multiple payers on one expense, `createdAt`, `type` (`TransactionType`: `expense` or `settlement`, stored as string), `createdBy`, `currency`, `isSynced`, `date` (user-facing/localized transaction date, distinct from `createdAt`).
- Balance math (see §5) credits each payer (from `payers`, or `paidBy` + full `amount` as fallback) and debits each member their `shares` amount. Settlement transactions are themselves `Transaction` rows of `type: 'settlement'`.
- All amounts are integer cents; rounding remainders from equal/percentage splits are distributed one cent at a time so totals are always exact.

**`AppUser`** (`user.dart`) — mirrors the `public.user` table:
- `uuid`, `name`, `utcOffset`, `timezone`, `email`, `groupsAllowed` (how many groups this user may **create**, default 1; `-1` means unlimited), `groupsJoined`, `groupsCreated`.

**`Purchase`** (`purchase.dart`) — a record of an IAP made to unlock more groups:
- `id`, `uid` (buyer), `createdAt`, `productId`, `amount`, `currency`, `groupsUnlocked`, `status`, `platform`, `transactionId`.

**`Reminder`** (`reminder.dart`) — a one-shot "please pay me" nudge:
- `fromId`, `toId`, `currency`, `amount` (int, cents), `text` (optional custom message), `groupId`. Inserting a row triggers a push notification via a Supabase DB webhook → Edge Function.

**`Currency`** (`currency.dart`) — a static value type, not persisted to the DB: `code`, `name`, `symbol`, `country`, `countryCode?`, `locale?`. A hardcoded catalog of ~45–50 currencies lives in `lib/providers/currency_provider.dart`.

There is no separate persisted "Balance" or "Settlement" entity — balances and settlement suggestions are computed on the fly from the `Transaction` list (see §5).

### 3.2 Supabase Schema (`supabase/migrations/`)

Single consolidated migration, schema `public`:

| Table | Key columns | Notes |
|---|---|---|
| `group` | `id` (bigint identity PK), `created_at`, `name` (default `'Group 1'`), `admin` (uuid), `access_code` (varchar, **unique**), `currency` (default `'USD'`), `locale` (default `'en-US'`), `local_id` (bigint, local-storage mapping), `image_url` | |
| `group_member` | `group_id` (bigint) + `member_id` (uuid), composite PK | Junction table. FKs: `group_id → group.id` CASCADE, `member_id → member.uid` CASCADE |
| `member` | `created_at`, `group_id` (bigint), `name`, `uid` (uuid PK, default `gen_random_uuid()`), `groups` (text[], legacy/unused) | |
| `transaction` | `id` (bigint identity PK), `title`, `description`, `amount` (double, cents), `created_at`, `group_id` (bigint, FK → `group.id` CASCADE), `paid_by` (uuid), `share_type` (varchar), `shares` (jsonb), `paid_to` (uuid, nullable), `type` (varchar, default `'expense'`), `created_by` (uuid), `currency` (varchar, default `'USD'`), `payers` (jsonb, nullable), `date` (timestamptz, default now) | |
| `user` | `uid` (uuid PK, FK → `auth.users.id` CASCADE), `name`, `email`, `created_at`, `timezone`, `utc_offset` (real), `groups_allowed` (int, default 1), `groups_created`/`groups_joined` (bigint, default 0), `fcm_token` | |
| `purchase` | `id` (bigint identity PK/unique), `created_at`, `product_id`, `groups_unlocked` (bigint), `amount` (double), `currency`, `uid`, `status` (default `'completed'`), `platform`, `transaction_id` | |
| `reminder` | `id` (bigint identity PK), `created_at`, `from_id`/`to_id` (uuid), `currency`, `amount` (bigint cents), `group_id`, `text` (nullable) | Index `idx_reminder_from_id_group_id_created_at` on `(from_id, group_id, created_at)`, used for rate-limiting |

**Row-Level Security (RLS)** — enforced per table:
- `group`: any authenticated user can insert/select; only the row's `admin` can update or delete.
- `member`: users can only select/update/delete their own row (`uid = auth.uid()`); any authenticated user can insert.
- `transaction`: any authenticated user can select/insert; update/delete restricted to `paid_by = auth.uid()` OR the group's admin.
- `user`: users can select/update only their own row; only a group admin can delete a user row.
- `purchase`: users can only insert/select their own purchases (`auth.uid() = uid`).
- `group_member`: open insert/select/delete for authenticated users.

---

## 4. Backend: RPCs, Webhooks & Edge Functions

**Postgres RPC functions** (called via `supabase.rpc(...)`):
- `increment_groups_created(user_id)` / `decrement_groups_created(user_id)`
- `increment_groups_joined(user_id)` / `decrement_groups_joined(user_id)`
- `update_transaction_dates()` — backfills `transaction.date` from `created_at` adjusted per-payer by `user.utc_offset`; returns row count.
- `update_transaction_dates_single_user(target_uid)` — same, scoped to one user.

**DB Webhooks → Deno Edge Functions** (in `supabase/functions/`), triggered on insert:
- `on_member_joined` (`group_member` insert) → **`group_notification`** — notifies existing members/admin when someone joins; skips if the joining member isn't a registered `user`.
- `on_reminder_sent` (`reminder` insert) → **`reminder_notification`** — sends a "settle up" push (or the custom reminder text) to the target member; rate-limited to 1/hour/group via the reminder index; clears invalid FCM tokens on send failure.
- `on_transaction_insert` (`transaction` insert) → **`transaction_notification`** — pushes to all members with a `share` (expense) or both parties (settlement), with localized currency-symbol titles/bodies. Uses the Firebase HTTP v1 API with a service-account JWT (`supabase/functions/service-account.json`).
- `purchase_completed_webhook` (`purchase` insert) → **`increment-groups-allowed`** — on `status === 'completed'`, deduplicates by `transaction_id`, and increments `user.groups_allowed` based on the `product_id` prefix (`1_splitup_group` → +1, `5_splitup_group` → +5, `10_splitup_group` → +10, `unlimited` → unlimited).

**Other Edge Functions**:
- **`delete-user`** — account-deletion endpoint; looks up groups admin'd by the user before deleting the auth user.
- **`update-transaction-dates`** — thin HTTP wrapper calling the `update_transaction_dates` RPC (batch backfill job).

---

## 5. State Management (`lib/providers/`)

All providers use `riverpod_annotation` (`@riverpod` for auto-dispose, `@Riverpod(keepAlive: true)` for app-wide/session state) with generated `.g.dart` parts via `build_runner`. Convention: `@riverpod` **functions** for pure/derived/fetched state; `@riverpod` **classes** (`Notifier`/`AsyncNotifier`, `extends _$ClassName`) for anything with mutating actions. Watch in `build()`, read in callbacks, listen for side effects. Controllers whose imperative methods `await` an I/O call and then touch `ref` afterward must be `keepAlive` to avoid disposal mid-await under Riverpod's auto-dispose.

### Group & Membership
- **`group_home_controller.dart`** — `GroupHomeController` (`AsyncNotifier<ExpenseGroup?>`): loads/persists the "currently selected group" (SharedPreferences key `selected_group_id`); `createNewGroup`, `joinGroup` (by access code), `removeGroup`, `selectGroup`, `generateAccessCode` (6-char, excludes ambiguous chars like O/0/I/1). Also exports the function provider `allGroups` (`Future<List<ExpenseGroup>>`).
- **`groups_settings_controller.dart`** — `GroupSettingsController` (keyed by `groupId`): `updateGroupName`, `updateGroupCurrency`, `updateGroupImage` (uploads to Supabase Storage bucket `images`), `removeMember` — all optimistic with rollback on error. Plus `groupMembers` (sorted list) and `pickImage` function providers.
- **`members_provider.dart`** — `MembersController` (**keepAlive**, keyed by `groupId`): `addMember`, `removeMember`. Plus `memberName` (looks up a name in the current group) and `isUserAdmin(String? adminId)`.
- **`allowed_groups_provider.dart`** — `userGroups` — a `Stream<Map<String,int>>` realtime Supabase subscription on the current user's `user` row, exposing `groups_allowed/joined/created` live.

### Transactions & Money
- **`transaction_controller.dart`** — `TransactionController` (keyed by `groupId`): `addTransaction`, `editTransaction`, `deleteTransaction`; companion `groupTransactions` provider handles cache invalidation. Also `formatCurrency` (locale-aware formatting), plus `StateProvider.family` filters `transactionTypeFilterProvider`/`transactionPayerFilterProvider` and a derived `filteredTransactionsProvider`.
- **`dashboard_controller.dart`** — all simple function providers: `totalGroupExpenses`, `memberExpense`, `memberShare`, `amountOwedTo`, `amountOwedBy`, `userNetBalance`, and the two key algorithms:
  - **`memberBalances`** — single pass over all of a group's transactions: credits each payer (from `payers`, or `paidBy` + full amount) and debits each member their `shares` amount; settlement transactions net out debts but are excluded from "total group expenses".
  - **`settlementSuggestions`** — a **greedy debt-simplification algorithm**: repeatedly finds the largest creditor and largest debtor, settles `min(creditor, |debtor|)` between them, updates both balances, and repeats until no balance remains (> 1 cent). This minimizes the number of settlement transactions needed. Result rows: `from`, `to`, `fromName`, `toName`, `amount`.
- **`currency_provider.dart`** — `groupCurrency` (per-group, falls back to locale), `localeCurrency` (device locale → currency), `getCurrencyByCode`, `getCurrencyByCountryCode`, `getCountryCodeFromLanguage`, `currencyOptionsList` (hardcoded ~50-entry catalog), `sortedCurrencyOptions`.

### Add/Edit Expense module (`lib/providers/add_expense/`)
- **`add_expense_controller.dart`** — `AddExpenseController` (`Notifier`, family-keyed by `(groupId, Transaction? transaction)` — null = create mode). Owns `AddExpenseState`, delegates to two plain (non-provider) collaborator classes:
  - **`share_calculator.dart`** — `ShareCalculator`: recomputes per-member share text controllers when amount/share-type/member-selection/payer-selection changes; supports equal/amount/percentage/portion split types and multi-payer amount splitting.
  - **`input_validator.dart`** — `InputValidator`: `validateShares`, `validatePayers` (multi-payer sum must match total, rounding-tolerant), `validateInput`, and `updateExpense` (the actual submit path — builds the final `shares`/`payers` maps in cents, distributes the rounding remainder, then calls `TransactionController.addTransaction`/`editTransaction`).
- **`add_expense_state.dart`** — `AddExpenseState`: holds `TextEditingController`s for amount/title/each member's share/each payer's amount, `selectedMembers`, `selectedPayers`, `shareType`, `selectedPaidBy`, `date`, etc.
- **`split_settings.dart`** — `SplitSettingsToggle` (bool, "remember my split settings") and `SplitSettings` (`Map<String,dynamic>?` storing last-used paidBy/payers/shareType/selectedMembers/shareValues), both family-keyed by `groupId` and persisted to SharedPreferences.

### App-level / Cross-cutting
- **`app_startup_provider.dart`** — `appStartup` (**keepAlive**): awaits `AppInitializer.initialize()`; gates the app's splash/startup UI.
- **`language_provider.dart`** — `Language` (`Notifier<Locale>`, **keepAlive**): persisted locale.
- **`theme_provider.dart`** — `ThemeNotifier` (`Notifier<ThemeMode>`): persisted theme mode (light/dark/system).
- **`user_name_provider.dart`** — `UserDisplayName` (`AsyncNotifier<String>`, **keepAlive**): persisted display name, defaulting to the Supabase auth metadata first name.
- **`loading_cta_provider.dart`** — `LoadingCta` (`Notifier<bool>`, family by string key): generic per-button loading/debounce flag, used with the `performAction` helper in `utils/extensions.dart`.
- **`pdf_preview_provider.dart`** — `PdfPreview` (`Notifier<PdfPreviewState>`): holds generated PDF bytes/filename/loading/error for the export preview screen.

---

## 6. Services (`lib/services/`)

- **`supabase_service.dart`** — abstract `SupabaseRepo` interface + its implementation `SupabaseApi`, exposed via `@Riverpod(keepAlive: true) SupabaseRepo supabaseApi(Ref ref)`. This is the single data-access layer wrapping the global `supabase` client (`lib/utils/constants.dart`). Methods: `upsertUser`, `getGroups`, `getGroupById`, `createGroup`, `updateGroup`, `getMembers`, `addMember`, `removeMember`, `getTransactions`, `addTransaction`, `editTransaction`, `deleteTransaction`, `findGroupByAccessCode`, `getAllowedGroups`, `registerPurchase`, `incrementUserGroupsJoined/Created`, `decrementUserGroupsJoined/Created`, `deleteGroup`, `updateFCMToken`, `sendPaymentReminder`, `updateMemberName`. Every method calls `ensureValidSession()` first and `handleSessionError(e)` on failure (see §6.1).
- **`app_initializer.dart`** — `AppInitializer.initialize()`: loads `.env` (via `flutter_dotenv`), validates `SUPABASE_URL`/`SUPABASE_ANON_KEY` are present (throws `FormatException` if not), calls `Supabase.initialize(...)`, logs a startup analytics event.
- **`logger.dart`** — free functions (no class), the app-wide logging/analytics facade: `logAppEvent(name, {params})` (prints + `Posthog().capture`), `logError(e, stackTrace)` (prints; Crashlytics call is commented out/disabled), `logInfo(message)` (prints). PostHog is the analytics backend; Firebase Analytics/Crashlytics are not actively used despite Firebase being present for messaging.
- **`notification_service.dart`** — `NotificationService` (`AsyncNotifier<void>`, **keepAlive**), wraps Firebase Cloud Messaging + `flutter_local_notifications` + `flutter_timezone`. Key methods: `initLocalTimeZone`, `cancelAllNotifications`, `hasNotificationPermissions`/`requestNotificationPermissions`, `initializeLocalNotifications` (Android channels `max_importance_channel` and `high_importance_channel`), `onTokenRefresh`/`updateToken` (pushes FCM token to Supabase via `updateFCMToken`), `listenToFCMEvents` (foreground/background/opened-app handlers), `showFCMNotification`. Top-level `backgroundMessageHandler`.
- **`payment_service.dart`** — `PaymentService` (`Notifier<void>`, **keepAlive**), wraps RevenueCat. `initPlatformState` (configures RevenueCat with platform-specific API keys — Android `goog_...` / iOS `appl_...`), `loginUser`/`logoutUser` (ties RevenueCat identity to the Supabase uid), `getStorefrontCountryCode`, `presentPaywall` (navigates to `/paywall`). Also exports `userSubscription` — checks `Purchases.getCustomerInfo()` entitlement `'pro'` (see §8.7 for how this relates to actual gating).

### 6.1 Session handling (`lib/utils/constants.dart`)
- Global `final supabase = Supabase.instance.client;` — the single client instance used everywhere.
- `ensureValidSession()` — checks `supabase.auth.currentSession`; if expired, calls `supabase.auth.refreshSession()`; returns `false`/logs on failure. Called at the top of nearly every `SupabaseApi` method — the app's core "keep the Supabase JWT alive" pattern.
- `handleSessionError(error)` — if the error is an `AuthException` "Refresh Token Not Found" (400), forces `supabase.auth.signOut()`.
- Other constants here: `userDisplayName` (derived from auth metadata `name`, first word only), `defaultCurrency`/`defaultCurrencyCode` (`$`/`USD`), layout constants `defaultMaxWidthConstraint`/`defaultMaxWidthConstraintDialog` (480.0).

---

## 7. Routing (`lib/route/router.dart`)

A single `@riverpod class AppRouter` (`RouterConfig` provider) builds one `GoRouter`, `initialLocation: '/auth'`, with a `PosthogObserver()` navigation observer for automatic screen-view analytics.

**Auth guard**: a global `redirect` callback checks `supabase.auth.currentSession`. Unauthenticated users are forced to `/auth`. An authenticated user landing on `/auth` triggers `paymentServiceProvider.loginUser()` (RevenueCat identity), a PostHog `identify` call, then redirect to `/home`.

| Path | Name | Screen | Extra data (`state.extra`) |
|---|---|---|---|
| `/auth` | `auth` | `AuthScreen` | none |
| `/home` | `home` | `GroupHomePage` or `NoGroupsPage` (chosen from `groupHomeControllerProvider` async state) | none |
| `/add-expense` | `add-expense` | `AddExpensePage` (slide from bottom) | `Map` with `groupId` (int) and `transaction` (`Transaction?` — non-null means edit mode) |
| `/transactions` | `transactions` | `TransactionsPage` (slide from right) | the `ExpenseGroup` object directly |
| `/group-settings` | `group-settings` | `GroupSettingsPage` (slide from bottom) | `Map` with `groupId` (int) |
| `/app-settings` | `app-settings` | `AppSettingsScreen` (slide from left) | none |
| `/paywall` | `paywall` | `AppPaywall` (slide from bottom) | none |

Data is passed via `state.extra`, not typed query params. Transitions come from `lib/route/transitions.dart` (`SlideTransitions.slideFromBottom/Right/Left`).

---

## 8. Features

### 8.1 Auth
`AuthScreen` + `AuthController` (StateNotifier). Sign-in is **Google Sign-In and Sign in with Apple only** (Apple button shown only on iOS/macOS); both exchange an id token for a Supabase session via `signInWithIdToken`. There is **no email/password auth**. On first sign-in, an `AppUser` row is upserted (uuid, email, name, timezone, utc offset) and the user is identified in PostHog. `setupAuthListener` reacts to Supabase auth-state changes and invalidates all user-scoped providers (groups, members, transactions, balances) on sign-in/out.

There is no multi-step onboarding carousel. Effectively, onboarding is: `AuthScreen` → on first login with zero groups, `NoGroupsPage` acts as the empty-state onboarding screen (Create Group / Join Group CTAs), with display-name entry happening inline in the create/join dialogs.

### 8.2 Groups
- **Creation** (`GroupHomeController.createNewGroup`): creates an `ExpenseGroup` with a random 6-character alphanumeric `accessCode` (ambiguous chars like O/0/I/1 excluded), auto-assigns currency from device locale, sets the creator as `admin` and first member, increments `groups_created`.
- **Join flow**: user enters a 6-char access code (`JoinGroupDialog`); `joinGroup()` looks up the group by `accessCode`, adds the user as a member, increments `groups_joined`. The invite is also shareable as text (access code + a generic link `https://onelink.to/etcezf`) from Group Settings.
- **Group Settings screen**: rename (admin-only), change currency (admin-only, searchable currency picker bottom sheet), view/copy/share access code, member list with per-member rename/remove (`MemberListItem`). Members referenced in any transaction cannot be removed until those transactions are cleared (guarded via `member_transaction_utils.dart`'s `memberIsReferencedInTransaction`).
- **Leaving/deleting**: admins can **Delete Group** (decrements `groups_created`); non-admins can **Leave Group** (removes themselves, decrements `groups_joined`).
- **Multi-group support**: `GroupHomeController` tracks the "selected" group (persisted in SharedPreferences); `SwitchGroupDialog`/`GroupSwitchButton` let a user switch between their groups.

### 8.3 Expenses & Splitting
Implemented across `lib/providers/add_expense/` and `lib/screens/create_expense/` (`AddExpensePage`, also used for editing).

- **Share types** (`Transaction.shareType`): `equally`, `amount`, `percentage`, `portion`.
  - **Equally**: every selected member gets weight `'1'`; the total is divided evenly at save time using integer-cent division, with any leftover cent distributed one at a time.
  - **Amount**: user enters an exact currency amount per member; live validation prevents the sum exceeding the total.
  - **Percentage**: entries must sum to ≤100%; changing one member's percentage auto-redistributes the remaining percentage evenly across the members that come after them in the selection order.
  - **Portion** ("shares"): free-form integer weights (e.g. 2 shares vs 1 share), no upper-bound validation — like Splitwise's "shares" mode.
  - All money math is integer cents (`(amount * 100).round()`), formatted back to 2 decimals for display.
- **Multiple payers**: `selectedPayers` defaults to the current user; picking a 2nd+ payer reveals per-payer amount fields that auto-split evenly and can be manually overridden. Stored in `Transaction.payers`; falls back to the single `paidBy` field when there's only one payer.
- **Currency**: driven by the group's `currency` field; `localeCurrencyProvider` infers a sensible default from device locale/country when a group is created.
- **Persisted split preferences**: `SplitSettings`/`SplitSettingsToggle` (SharedPreferences, per-group) let a user opt in to remembering their last-used payer/split config for faster repeat entry.
- Notably **absent**: no expense categories/tags, no recurring/repeating expenses, no receipt photo attachment field on `Transaction` itself (though `image_picker` is a dependency, used for group images).

### 8.4 Dashboard & Balances
`DashboardPage` → `DashboardContent`: horizontal member chips, `DashboardStats` (total group expense + the current user's own share via `UserShareCard`), `MemberBalanceCard` (current user's net balance), `SettlementSuggestions` (see the greedy algorithm in §5, with a share button), a recent-transactions list (last 5, "View all" → transactions page), `EmptyGroupView` (shown when the group has only 1 member, prompting invites), `MemberOverview` (per-member balance drill-down dialog), and `ExportGroupDataCard`/`ExportGroupDataDialog`/`PdfPreviewSheet` for export (see §8.10).

### 8.5 Transactions List
`TransactionsPage`: date-grouped (newest first) list of all expenses + settlements for a group, with `TransactionFilters` (All / Expense / Payment chips, plus a "paid by" member filter). Swipe-to-delete is restricted to the transaction's creator or the group admin, with type-specific confirmation dialogs. Sub-widgets: `transaction_card.dart`, `transaction_details_dialog.dart` (expense detail/edit entry), `payment_details_dialog.dart` (settlement detail), `payment_dialog.dart` (quick "settle up" entry point), `settlement_card.dart`/`settlement_dialog.dart`, `reminder_bottom_sheet.dart`.

### 8.6 Settlements & Reminders
From a settlement suggestion (or the "Add Payment" quick action), a user can record a settlement via `showSettlementDialog` (editable amount, defaults to the suggested amount) — this creates a new `Transaction` of `type: 'settlement'` — or send a **reminder** instead of settling immediately.

**Reminders** (`entities/reminder.dart`, `transactions/widgets/reminder_bottom_sheet.dart`, `utils/reminder_texts.dart`): 4 tone presets — 😊 friendly / 😐 neutral / 😠 firm / 🤬 rude — each with randomized message templates substituting name/amount/currency. The user can regenerate the message, copy it, share it externally, or send it as an in-app push via `sendPaymentReminder` (inserting into `reminder`, which triggers the `reminder_notification` Edge Function — rate-limited to 1/hour/group).

### 8.7 Monetization (RevenueCat)
`PaymentService` configures the RevenueCat SDK (separate Play/App Store API keys) and logs the Supabase user id into RevenueCat on login/logout. It exposes `userSubscriptionProvider` checking the `'pro'` entitlement, but **this entitlement doesn't appear to directly gate anything in the app** — the actual gating mechanism is group-count-based:

- The number of groups a user can **create** is capped by the server-tracked `user.groups_allowed` field (`groups_created >= groups_allowed` → paywall triggered; `groups_allowed == -1` means unlimited).
- Users can always **join** groups created by others regardless of their own creation limit.
- **Paywall UI** (`lib/screens/paywall/paywall.dart`) renders RevenueCat's own hosted `PaywallView`, listens for `onPurchaseCompleted`, parses the purchased product id's prefix to determine groups unlocked (`10_...` → +10, `5_...` → +5, `1_...` → +1, `unlimited_...` → unlimited), shows a success toast, and records the purchase via `PaywallController.registerPurchase` (which the `increment-groups-allowed` Edge Function then applies server-side).
- Presented from `NoGroupsPage` (create-group limit reached) and `AppSettingsScreen` ("Unlock more groups" button).
- These are one-time consumable "group pack" purchases, not a recurring subscription tier, despite the subscription-flavored `'pro'` entitlement code existing.

### 8.8 Notifications
`NotificationService` sets up Firebase Messaging: foreground presentation options, FCM token registration/refresh synced to Supabase, local notification display for foreground Android messages via two channels ("Settlement Reminders" max-importance, "Group Notifications" high-importance), a background message handler, timezone init, and notification-tap analytics. Permission is requested when entering `GroupHomePage`, which also subscribes to a `general` FCM topic.

### 8.9 Settings
`AppSettingsScreen` ("Profile"): account card (avatar initial, editable name, email, groups-created/allowed/joined stat tiles, "Unlock more groups" CTA → paywall), theme toggle (light/dark/system via `themeProvider`), language picker (10 languages, bottom sheet, persisted via `languageProvider`), Rate App (native in-app review), Send Feedback (mailto enriched with device/app diagnostics), app version display, Logout, Delete Account (calls the `delete-user` Edge Function). `edit_name_dialog.dart` is shared for editing display names (own, or a group member's if admin). A dedicated `language_settings_screen.dart` also exists alongside the in-settings picker.

### 8.10 Export
Per-group **PDF** (`utils/export_data/pdf_writer.dart`, `GroupPdfWriter`, with an in-app preview sheet backed by `pdfPreviewProvider`) and **Excel** (`excel_writer.dart`, `GroupExcelWriter`) reports containing members, balances, settlement suggestions, and full transaction history — shareable/saveable via `share_plus` and `file_helper.dart` (handles storage permissions).

### 8.11 Other notable features
- **Dark/light/system theming** via `ThemeNotifier`, persisted.
- **Search/filter**: Transactions page filters by type and by payer; the currency picker supports text search over country/code/name.
- **Analytics**: PostHog event logging (`logAppEvent`) throughout key actions (login, create/join/delete/leave group, add/edit/delete transaction, export, paywall, reminders), plus automatic screen-view tracking via `PosthogObserver`.
- **Account deletion** available from Settings.

---

## 9. Conventions & Standards

These reflect the *actual current* conventions (per `standard_code_guide.md`/`CLAUDE.md`), not the more generic `.github/copilot-instructions.md` template.

- **Naming**: `snake_case.dart` files, `PascalCase` classes, `camelCase` variables/methods. Suffixes `Entity`, `Model`, `Repository`/`RepositoryImpl`, `Provider`, `Service`.
- **Riverpod codegen**: one provider file per responsibility; `@riverpod` **functions** for derived/fetched state; `@riverpod` **classes** (`extends _$ClassName`) for mutable state/actions; `FutureOr`/async `build()` for network/DB-backed state so the UI always deals in `AsyncValue`. **Auto-dispose by default** — only use `@Riverpod(keepAlive: true)` for genuinely app-wide/session state (real examples: `MembersController`, `AuthController`, `PaymentService`, `NotificationService`, `SupabaseApi`'s provider, `AppRouter`, `app_startup_provider`, `language_provider`). Parameters are passed directly to `build()`, not via `.family` boilerplate patterns. Watch/read/listen discipline: `ref.watch` in `build()`, `ref.read` in callbacks, `ref.listen` for side effects. **Gotcha**: a controller whose method is called imperatively and does `await someIoCall()` then touches `ref` afterward risks disposal mid-await under auto-dispose — such controllers must be `keepAlive`.
- **No `freezed`** — entities are plain classes with hand-written `fromJson`/`toMap`/`copyWith`.
- **No typed exception hierarchy** — ad hoc try/catch in `services/`, rethrown as `Exception('Failed to ...: $e')`, logged via `logError()`; controllers set `AsyncValue.error`.
- **Money is integer cents** everywhere (app and DB) — never raw `double` currency math; divide by 100.0 only for display.
- **Styling single source of truth** (`lib/styles/`): `AppColors` (hand-picked constants, not `ColorScheme.fromSeed` — brand primary is yellow `0xFFFFDB1F`), `AppTextStyles` (Google Fonts **Poppins**, a type scale `h1`–`h3`/`p1`–`p6`/`label`) plus a `TextStyleExtension` on `TextStyle` (`.bold`, `.boldWeight()`, `.colored()`, `.fontS()`, `.wordSp()` — used instead of raw `.copyWith()`), `AppTheme` (two full `ThemeData` — `useMaterial3: true`, explicit `ColorScheme(...)` rather than `fromSeed`; Material button theming is present but **commented out** in favor of hand-rolled stateful button widgets like `AppPrimaryButton`, which implements a neo-brutalist "pressed" effect — offset translate + hard-edged `BoxShadow` on tap-down), `AppImage`/`AppSvgLibrary`/`AppPngLibrary` (the only sanctioned way to render images/reference asset paths — never call `Image.asset`/`SvgPicture.asset` or use a raw string literal path), and toast helpers `showInfoToast`/`showSuccessToast`/`showWarningToast`/`showErrorToast` in `widgets/app_toast.dart` (wrapping `toastification` — never use `ScaffoldMessenger`/`SnackBar` directly). New files under `styles/` should use an `app_` prefix; the legacy files `colors.dart`, `text_styles.dart`, `theme.dart`, `buttons.dart` predate that rule and should be migrated opportunistically when touched.
- **Widget decomposition**: no "god widgets" — split any `build()` over ~60–80 lines or mixing layout+logic; prefer real widget classes over private `_buildXyz()` helper methods (helpers can't be `const` and always rebuild). Extract reactive subtrees into their own widget, watch as low as possible (`.select()` for a single field), wrap static subtrees in `const`/`RepaintBoundary`, use stable `key`s in list/grid builders, use `const` constructors everywhere possible.
- **Localization**: edit `lib/l10n/app_en.arb` (template, ~277 keys) plus the mirrored `app_<locale>.arb` files (`ar`, `bn`, `es`, `fr`, `hi`, `it`, `ru`, `ur`, `zh` — 10 total), then run `flutter gen-l10n` (never hand-edit `lib/gen/`). All user-facing strings go through `AppLocalizations`. Since Arabic and Urdu are RTL, prefer `EdgeInsetsDirectional`/`AlignmentDirectional` over hardcoded `left`/`right`.
- **Lint** (`analysis_options.yaml`, `custom_lint` + `riverpod_lint` + `flutter_lints`, ~90 explicit rules on top of the defaults; generated code (`**/*.g.dart`, `**/l10n/**`) is excluded from analysis). Notable non-default rules: `avoid_print` (use the logger service, not `print()`), `prefer_relative_imports` + `avoid_relative_lib_imports`, `unawaited_futures` (wrap intentional fire-and-forget with `unawaited()`), `cancel_subscriptions`, `use_build_context_synchronously`, `always_declare_return_types` **combined with** `omit_local_variable_types` (explicit return types on functions, but rely on inference for locals — a specific style to match), `avoid_types_on_closure_parameters`, `prefer_final_locals`/`prefer_final_fields`/`prefer_final_in_for_each`, `cast_nullable_to_non_nullable`, `avoid_catching_errors` (only catch `Exception`s, not `Error`s), `directives_ordering`, `sort_child_properties_last`, `sized_box_for_whitespace`, `use_named_constants`, `avoid_unnecessary_containers`. `prefer_const_constructors` and related `const` rules are **not** currently in the explicit list — a known gap.
- **Session handling**: nearly every `SupabaseApi` method calls `ensureValidSession()`/`handleSessionError()` (see §6.1) — replicate this pattern for any new Supabase-calling service method.
- Run `dart format .` and `fvm flutter analyze` before committing (no CI enforces this automatically — see §11).

---

## 10. Build & Tooling

Requires a `.env` file at the repo root (bundled as a Flutter asset) with `SUPABASE_URL` and `SUPABASE_ANON_KEY` — `AppInitializer.initialize()` throws if either is missing.

```bash
# Install dependencies
fvm flutter pub get

# Regenerate Riverpod providers (*.g.dart) after editing an @riverpod class/function
fvm flutter pub run build_runner build --delete-conflicting-outputs
# shortcut used by this repo (also regenerates localization):
sh build_runner.sh

# Regenerate localization (lib/gen/app_localizations*.dart) after editing lib/l10n/*.arb
fvm flutter gen-l10n

# Lint (flutter_lints + custom_lint/riverpod_lint)
fvm flutter analyze

# Run tests
fvm flutter test
fvm flutter test test/some_test.dart          # single file
fvm flutter test test/some_test.dart -n "name" # single test by name

# Run the app
fvm flutter run

# Full clean + pod reinstall (iOS)
sh flutter_clean.sh   # flutter clean, pub get, then cd ios && pod update && pod install --repo-update

# Release builds (each runs build_runner build -d first, so generated code is always fresh)
sh build_android_apk.sh        # Android release APK
sh build_android_appbundle.sh  # Android app bundle
sh build_ios.sh                # iOS ipa
```

**Startup sequence** (`lib/main.dart`): the whole `main()` is wrapped in `runZonedGuarded` (uncaught async errors → `logError`) → `WidgetsFlutterBinding.ensureInitialized()` → `Firebase.initializeApp(...)` → `setupPostHog()` (configures `PostHogConfig` — a hardcoded project key, `debug = kDebugMode`, `captureApplicationLifecycleEvents = true`, host `https://us.i.posthog.com`, **session replay enabled only in release** with `maskAllTexts = false` and `maskAllImages = false` — i.e. replay does *not* mask text/images, worth keeping in mind for anything privacy-sensitive) → `runApp` wraps the tree in `ProviderScope` → `PostHogWidget` → `AppBootstrap`. `AppBootstrap` watches `appStartupProvider` and `themeProvider`: loading shows a bare `MaterialApp` with a spinner; error shows an "Initialization failed" screen with a Retry button (`ref.invalidate(appStartupProvider)`); data renders the real `MyApp`. `appStartupProvider`'s entire body is `await AppInitializer.initialize();` (loads `.env`, validates keys, calls `Supabase.initialize`, logs a `supabase_initialization` PostHog event). Once resolved, `MyApp` calls `paymentServiceProvider.notifier.initPlatformState()` (RevenueCat init) and renders `MaterialApp.router` (wired to `appRouterProvider`) wrapped in `ToastificationWrapper` and `UpgradeAlert` (from the `upgrader` package — forced/soft update prompts, Cupertino style, 2-day re-prompt, custom copy via `AppUpgradeMessages`).

**Key `pubspec.yaml` dependencies** beyond what's covered above: `flutter_riverpod ^3.1.0`, `riverpod_annotation ^4.0.0` / `riverpod_generator ^4.0.0+1` / `riverpod_lint ^3.1.0` + `custom_lint ^0.8.1`, `supabase_flutter ^2.16.0`, `firebase_core ^4.11.0` / `firebase_messaging ^16.4.1`, `google_sign_in ^7.2.0` / `sign_in_with_apple ^8.1.0` / `auth_buttons ^3.0.2`, `purchases_flutter`/`purchases_ui_flutter` (pinned exact `10.4.2`), `posthog_flutter ^5.30.0`, `upgrader ^13.6.0`, `in_app_review ^2.0.10`, `flutter_local_notifications ^22.3.0` / `flutter_timezone ^5.0.1`, `permission_handler ^13.0.1`, `device_info_plus ^13.2.0` / `package_info_plus ^10.2.1`, `google_fonts ^6.2.1`, `flutter_animate ^4.5.2`, `shimmer ^3.0.0`, `toastification ^3.0.3`, `cached_network_image ^3.4.1`, `swipeable_page_route ^0.4.7`, `image_picker ^1.0.7`, `excel ^4.0.6` / `pdf ^3.11.3` / `pdfx ^2.9.2`, `path_provider ^2.1.5` / `share_plus ^13.3.0`, `go_router ^17.1.0`, `intl ^0.20.2`, `shared_preferences ^2.5.4`, `flutter_dotenv ^6.0.0`, `crypto ^3.0.6`, `uuid ^4.3.3`, `jiffy ^6.3.2`, `url_launcher ^6.2.2`. Dev tooling also includes `android_notification_icons` (generates Android notification icons from `assets/icons/logo.png`) and `flutter_launcher_icons` (app icon generation).

---

## 11. Known Gaps / Things to Watch For

- **Zero test coverage** — `test/` exists but is completely empty. No unit, widget, or golden tests exist despite `flutter_test` being a dev dependency and `fvm flutter test` being a documented command. There is no existing pattern/fixture/fake to mirror; the intended approach (per `standard_code_guide.md`, not yet实现) is Riverpod `ProviderContainer`/`overrideWith` to mock `services/` providers rather than a mocking framework like `mocktail`/`mockito` (neither is a dependency).
- **No CI/CD** — no `.github/workflows/`, no Fastlane. All linting/testing/building is manual, via the root shell scripts.
- **Two partially conflicting docs**: `.github/copilot-instructions.md` is a fairly generic Clean-Architecture template (implies a UseCase layer, generic example versions) that only loosely matches reality; `standard_code_guide.md` and `CLAUDE.md` are accurate and current — prefer them (and this document) when they disagree. `copilot-instructions-firebase.md` at the repo root is obsolete (a template for an unrelated Firebase-primary stack) and should be ignored.
- **Legacy style filenames**: `lib/styles/colors.dart`, `text_styles.dart`, `theme.dart`, `buttons.dart` predate the `app_` prefix convention; rename opportunistically when touched, not proactively.
- **Material button theming is commented out** in `AppTheme` in favor of hand-rolled stateful widgets (`AppPrimaryButton` etc.) with a custom offset-shadow "pressed" effect — don't re-enable it without checking why it was disabled.
- **`README.md` is stale** — it describes a phased roadmap using "Trip" terminology and lists phases as if unimplemented; the real codebase already implements groups/members/expenses/dashboard/settlement extensively and uses "Group" terminology throughout (`ExpenseGroup`, `group_home_controller.dart`, etc.). Prefer the actual code/entity names over the README.
- **PostHog session replay** is enabled in release builds with `maskAllTexts = false` and `maskAllImages = false` — text and images are *not* masked in replay recordings; be mindful of this if adding screens that display sensitive data.
- **`prefer_const_constructors` and related `const` lint rules are not yet enabled** in `analysis_options.yaml` even though the coding convention calls for `const` usage everywhere possible — don't assume the linter will catch missing `const`.
- **RevenueCat `'pro'` entitlement code exists but isn't actually wired to feature gating** — the real gating mechanism is the `groups_allowed`/`groups_created` counter pair on the `user` table, driven by one-time consumable purchases, not a subscription entitlement check.
