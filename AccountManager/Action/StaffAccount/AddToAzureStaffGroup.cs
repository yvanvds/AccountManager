using AccountApi;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.Action.StaffAccount
{
    public class AddToAzureStaffGroup : AccountAction
    {
        public AddToAzureStaffGroup() : base(
            "Toevoegen aan leraren groep in Office365",
            "Wanneer dit account geen lid is van deze group, heeft de gebruiker geen licentie.",
            true, true)
        {

        }

        public async override Task Apply(State.Linked.LinkedStaffMember account)
        {
            var user = account.Azure.Account;
            if (account.Smartschool.Account.Role == AccountRole.Director)
            {
                await Add(directorGroup, user).ConfigureAwait(false);
                await Add(directorGroupSec, user).ConfigureAwait(false);
                await Remove(supportGroup, user).ConfigureAwait(false);
                await Remove(supportGroupSec, user).ConfigureAwait(false);
                await Remove(teacherGroup, user).ConfigureAwait(false);
                await Remove(teacherGroupSec, user).ConfigureAwait(false);
            }

            if (account.Smartschool.Account.Role == AccountRole.Support || account.Smartschool.Account.Role == AccountRole.IT)
            {
                await Remove(directorGroup, user).ConfigureAwait(false);
                await Remove(directorGroupSec, user).ConfigureAwait(false);
                await Add(supportGroup, user).ConfigureAwait(false);
                await Add(supportGroupSec, user).ConfigureAwait(false);
                await Remove(teacherGroup, user).ConfigureAwait(false);
                await Remove(teacherGroupSec, user).ConfigureAwait(false);
            }

            if (account.Smartschool.Account.Role == AccountRole.Teacher)
            {
                await Remove(directorGroup, user).ConfigureAwait(false);
                await Remove(directorGroupSec, user).ConfigureAwait(false);
                await Remove(supportGroup, user).ConfigureAwait(false);
                await Remove(supportGroupSec, user).ConfigureAwait(false);
                await Add(teacherGroup, user).ConfigureAwait(false);
                await Add(teacherGroupSec, user).ConfigureAwait(false);
            }
        }

        public static void Evaluate(State.Linked.LinkedStaffMember account)
        {
            var user = account.Azure.Account;

            if (!groupsLoaded)
            {
                loadGroups();
            }
            if (!groupsLoaded) return;

            if (account.Smartschool.Account.Role == AccountRole.Director)
            {
                if (!directorGroup.HasMember(user) || !directorGroupSec.HasMember(user) || supportGroup.HasMember(user) || supportGroupSec.HasMember(user) || teacherGroup.HasMember(user) || teacherGroupSec.HasMember(user)) {
                    account.Azure.FlagWarning();
                    account.Actions.Add(new AddToAzureStaffGroup());
                    return;
                }
            }

            if (account.Smartschool.Account.Role == AccountRole.Support)
            {
                if (directorGroup.HasMember(user) || directorGroupSec.HasMember(user) || !supportGroup.HasMember(user) || !supportGroupSec.HasMember(user) || teacherGroup.HasMember(user) || teacherGroupSec.HasMember(user)) {
                    account.Azure.FlagWarning();
                    account.Actions.Add(new AddToAzureStaffGroup());
                    return;
                }
            }

            if (account.Smartschool.Account.Role == AccountRole.IT)
            {
                if (directorGroup.HasMember(user) || directorGroupSec.HasMember(user) || !supportGroup.HasMember(user) || !supportGroupSec.HasMember(user) || teacherGroup.HasMember(user) || teacherGroupSec.HasMember(user)) {
                    account.Azure.FlagWarning();
                    account.Actions.Add(new AddToAzureStaffGroup());
                    return;
                }
            }

            if (account.Smartschool.Account.Role == AccountRole.Teacher)
            {
                if (directorGroup.HasMember(user) || directorGroupSec.HasMember(user) || supportGroup.HasMember(user) || supportGroupSec.HasMember(user) || !teacherGroup.HasMember(user) || !teacherGroupSec.HasMember(user)) {
                    account.Azure.FlagWarning();
                    account.Actions.Add(new AddToAzureStaffGroup());
                    return;
                }
            }
        }

        private static bool groupsLoaded;
        private static AccountApi.Azure.Group teacherGroupSec;
        private static AccountApi.Azure.Group supportGroupSec;
        private static AccountApi.Azure.Group directorGroupSec;
        private static AccountApi.Azure.Group teacherGroup;
        private static AccountApi.Azure.Group supportGroup;
        private static AccountApi.Azure.Group directorGroup;

        private static void loadGroups()
        {
            teacherGroupSec = AccountApi.Azure.GroupManager.Instance.FindGroupByName(State.App.Instance.Settings.SchoolPrefix.Value + "-Leraren", true);
            supportGroupSec = AccountApi.Azure.GroupManager.Instance.FindGroupByName(State.App.Instance.Settings.SchoolPrefix.Value + "-Secretariaat", true);
            directorGroupSec = AccountApi.Azure.GroupManager.Instance.FindGroupByName(State.App.Instance.Settings.SchoolPrefix.Value + "-Directie", true);

            teacherGroup = AccountApi.Azure.GroupManager.Instance.FindGroupByName(State.App.Instance.Settings.SchoolPrefix.Value + "-Leraren", true);
            supportGroup = AccountApi.Azure.GroupManager.Instance.FindGroupByName(State.App.Instance.Settings.SchoolPrefix.Value + "-Secretariaat", true);
            directorGroup = AccountApi.Azure.GroupManager.Instance.FindGroupByName(State.App.Instance.Settings.SchoolPrefix.Value + "-Directie", true);

            if (teacherGroup == null || supportGroup == null || directorGroup == null || teacherGroupSec == null || supportGroupSec == null || directorGroupSec == null)
            {
                MainWindow.Instance.Log.AddError(Origin.Azure, "Niet alle personeelsgroepen werden gevonden");
            } else
            {
                groupsLoaded = true;
            }
        }

        private static async Task Add(AccountApi.Azure.Group group, AccountApi.Azure.User user)
        {
            if (!group.HasMember(user)) await group.AddMember(user).ConfigureAwait(false); 
        }

        private static async Task Remove(AccountApi.Azure.Group group, AccountApi.Azure.User user)
        {
            if (group.HasMember(user)) await group.RemoveMember(user).ConfigureAwait(false);
        }

    }
}
