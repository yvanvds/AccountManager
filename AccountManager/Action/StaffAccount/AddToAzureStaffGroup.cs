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
            "Toevoegen aan groepen in Office365",
            "Wanneer dit account geen lid is personeelsgroepen, heeft de gebruiker geen licentie.",
            true, true)
        {

        }

        public async override Task Apply(State.Linked.LinkedStaffMember account)
        {
            var user = account.Azure.Account;
            if (account.Smartschool.Account.Role == AccountRole.Director)
            {
                await Add(directorGroup, user).ConfigureAwait(false);
                await Remove(supportGroup, user).ConfigureAwait(false);
                await Remove(teacherGroup, user).ConfigureAwait(false);
                await Add(staffGroup, user).ConfigureAwait(false);
            }

            if (account.Smartschool.Account.Role == AccountRole.Support || account.Smartschool.Account.Role == AccountRole.IT)
            {
                await Remove(directorGroup, user).ConfigureAwait(false);
                await Add(supportGroup, user).ConfigureAwait(false);
                await Remove(teacherGroup, user).ConfigureAwait(false);
                await Add(staffGroup, user).ConfigureAwait(false);
            }

            if (account.Smartschool.Account.Role == AccountRole.Teacher)
            {
                await Remove(directorGroup, user).ConfigureAwait(false);
                await Remove(supportGroup, user).ConfigureAwait(false);
                await Add(teacherGroup, user).ConfigureAwait(false);
                await Add(staffGroup, user).ConfigureAwait(false);
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
                if (!directorGroup.HasMember(user) || supportGroup.HasMember(user) ||  teacherGroup.HasMember(user) || !staffGroup.HasMember(user)) {
                    account.Azure.FlagWarning();
                    account.Actions.Add(new AddToAzureStaffGroup());
                    return;
                }
            }

            if (account.Smartschool.Account.Role == AccountRole.Support)
            {
                if (directorGroup.HasMember(user) || !supportGroup.HasMember(user) || teacherGroup.HasMember(user) || !staffGroup.HasMember(user)) {
                    account.Azure.FlagWarning();
                    account.Actions.Add(new AddToAzureStaffGroup());
                    return;
                }
            }

            if (account.Smartschool.Account.Role == AccountRole.IT)
            {
                if (directorGroup.HasMember(user) || !supportGroup.HasMember(user) || teacherGroup.HasMember(user) || !staffGroup.HasMember(user)) {
                    account.Azure.FlagWarning();
                    account.Actions.Add(new AddToAzureStaffGroup());
                    return;
                }
            }

            if (account.Smartschool.Account.Role == AccountRole.Teacher)
            {
                if (directorGroup.HasMember(user) || supportGroup.HasMember(user) || !teacherGroup.HasMember(user) || !staffGroup.HasMember(user)) {
                    account.Azure.FlagWarning();
                    account.Actions.Add(new AddToAzureStaffGroup());
                    return;
                }
            }
        }

        private static bool groupsLoaded;
        private static AccountApi.Azure.Group teacherGroup;
        private static AccountApi.Azure.Group supportGroup;
        private static AccountApi.Azure.Group directorGroup;
        private static AccountApi.Azure.Group staffGroup;

        private static void loadGroups()
        {
            teacherGroup = AccountApi.Azure.GroupManager.Instance.FindGroupByName(State.App.Instance.Settings.SchoolPrefix.Value + "-Leraren", true);
            supportGroup = AccountApi.Azure.GroupManager.Instance.FindGroupByName(State.App.Instance.Settings.SchoolPrefix.Value + "-Secretariaat", true);
            directorGroup = AccountApi.Azure.GroupManager.Instance.FindGroupByName(State.App.Instance.Settings.SchoolPrefix.Value + "-Directie", true);
            staffGroup = AccountApi.Azure.GroupManager.Instance.FindGroupByName(State.App.Instance.Settings.SchoolPrefix.Value + "-Personeel", true);

            if (teacherGroup == null || supportGroup == null 
                || directorGroup == null || staffGroup == null)
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
