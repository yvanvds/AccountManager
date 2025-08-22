using AccountApi;
using AccountManager.State.Linked;
using AccountManager.Utils;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using System.Windows.Documents;

namespace AccountManager.Action.StaffAccount
{
    public class AddToAzureStaffGroup : AccountAction
    {
        public AddToAzureStaffGroup() : base(
            "Toevoegen aan groepen in Office365",
            "Wanneer dit account geen lid is personeelsgroepen, heeft de gebruiker geen licentie.",
            true)
        {
            CanShowDetails = true;
        }

        public override FlowDocument GetDetails(LinkedStaffMember account)
        {
            var result = new FlowTableCreator(false);
            result.SetHeaders(new string[] {"Security", "Groep", "Lid?" });
            result.AddRow(new List<string>() { "", "", staffGroup.DisplayName, staffGroup.HasMember(account.Azure.Account) ? "Ja" : "Nee" });
            result.AddRow(new List<string>() { "", "", supportGroup.DisplayName, supportGroup.HasMember(account.Azure.Account) ? "Ja" : "Nee" });
            result.AddRow(new List<string>() { "", "", directorGroup.DisplayName, directorGroup.HasMember(account.Azure.Account) ? "Ja" : "Nee" });
            result.AddRow(new List<string>() { "", "*", secStaffGroup.DisplayName, secStaffGroup.HasMember(account.Azure.Account) ? "Ja" : "Nee" });
            result.AddRow(new List<string>() { "", "*", secSupportGroup.DisplayName, secSupportGroup.HasMember(account.Azure.Account) ? "Ja" : "Nee" });
            result.AddRow(new List<string>() { "", "*", secDirectorGroup.DisplayName, secDirectorGroup.HasMember(account.Azure.Account) ? "Ja" : "Nee" });
            
            FlowDocument document = new FlowDocument();
            document.Blocks.Add(result.Create());

            // add Current Role
            var paragraph = new Paragraph();
            paragraph.Inlines.Add(new Run("Role: " + account.Smartschool.Account.Role.ToString()));

            document.Blocks.Add(paragraph);

            return document;
        }

        public async override Task Apply(State.Linked.LinkedStaffMember account)
        {
            var user = account.Azure.Account;
            if (account.Smartschool.Account.Role == AccountRole.Director)
            {
                await Add(directorGroup, user).ConfigureAwait(false);
                await Remove(supportGroup, user).ConfigureAwait(false);
                await Add(staffGroup, user).ConfigureAwait(false);

                await Add(secDirectorGroup, user).ConfigureAwait(false);
                await Remove(secSupportGroup, user).ConfigureAwait(false);
                await Add(secStaffGroup, user).ConfigureAwait(false);
            }

            if (account.Smartschool.Account.Role == AccountRole.Support || account.Smartschool.Account.Role == AccountRole.IT)
            {
                await Remove(directorGroup, user).ConfigureAwait(false);
                await Add(supportGroup, user).ConfigureAwait(false);
                await Add(staffGroup, user).ConfigureAwait(false);

                // Security groups
                await Remove(secDirectorGroup, user).ConfigureAwait(false);
                await Add(secSupportGroup, user).ConfigureAwait(false);
                await Add(secStaffGroup, user).ConfigureAwait(false);
            }

            if (account.Smartschool.Account.Role == AccountRole.Teacher)
            {
                await Remove(directorGroup, user).ConfigureAwait(false);
                await Remove(supportGroup, user).ConfigureAwait(false);
                await Add(staffGroup, user).ConfigureAwait(false);

                // Security groups
                await Remove(secDirectorGroup, user).ConfigureAwait(false);
                await Remove(secSupportGroup, user).ConfigureAwait(false);
                await Add(secStaffGroup, user).ConfigureAwait(false);
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
                if (!directorGroup.HasMember(user) || !supportGroup.HasMember(user) || !staffGroup.HasMember(user)) {
                    account.Azure.FlagWarning();
                    account.Actions.Add(new AddToAzureStaffGroup());
                    return;
                }

                if (!secDirectorGroup.HasMember(user) || !secSupportGroup.HasMember(user) || !secStaffGroup.HasMember(user))
                {
                    account.Azure.FlagWarning();
                    account.Actions.Add(new AddToAzureStaffGroup());
                    return;
                }
            }

            if (account.Smartschool.Account.Role == AccountRole.Support)
            {
                if (directorGroup.HasMember(user) || !supportGroup.HasMember(user) || !staffGroup.HasMember(user)) {
                    account.Azure.FlagWarning();
                    account.Actions.Add(new AddToAzureStaffGroup());
                    return;
                }

                if (secDirectorGroup.HasMember(user) || !secSupportGroup.HasMember(user) || !secStaffGroup.HasMember(user))
                {
                    account.Azure.FlagWarning();
                    account.Actions.Add(new AddToAzureStaffGroup());
                    return;
                }
            }

            if (account.Smartschool.Account.Role == AccountRole.IT)
            {
                if (directorGroup.HasMember(user) || !supportGroup.HasMember(user) || !staffGroup.HasMember(user)) {
                    account.Azure.FlagWarning();
                    account.Actions.Add(new AddToAzureStaffGroup());
                    return;
                }

                if (secDirectorGroup.HasMember(user) || !secSupportGroup.HasMember(user)|| !secStaffGroup.HasMember(user))
                {
                    account.Azure.FlagWarning();
                    account.Actions.Add(new AddToAzureStaffGroup());
                    return;
                }
            }

            if (account.Smartschool.Account.Role == AccountRole.Teacher)
            {
                if (directorGroup.HasMember(user) || supportGroup.HasMember(user) || !staffGroup.HasMember(user)) {
                    account.Azure.FlagWarning();
                    account.Actions.Add(new AddToAzureStaffGroup());
                    return;
                }

                if (secDirectorGroup.HasMember(user) || secSupportGroup.HasMember(user) || !secStaffGroup.HasMember(user))
                {
                    account.Azure.FlagWarning();
                    account.Actions.Add(new AddToAzureStaffGroup());
                    return;
                }
            }
        }

        private static bool groupsLoaded;
        //private static AccountApi.Azure.Group teacherGroup;
        private static AccountApi.Azure.Group supportGroup;
        private static AccountApi.Azure.Group directorGroup;
        private static AccountApi.Azure.Group staffGroup;

        //private static AccountApi.Azure.Group secTeacherGroup;
        private static AccountApi.Azure.Group secSupportGroup;
        private static AccountApi.Azure.Group secDirectorGroup;
        private static AccountApi.Azure.Group secStaffGroup;

        public static void loadGroups()
        {
            //teacherGroup = AccountApi.Azure.GroupManager.Instance.FindGroupByName(State.App.Instance.Settings.SchoolPrefix.Value + "-Leraren", false);
            supportGroup = AccountApi.Azure.GroupManager.Instance.FindGroupByName(State.App.Instance.Settings.SchoolPrefix.Value + "-Secretariaat", false);
            directorGroup = AccountApi.Azure.GroupManager.Instance.FindGroupByName(State.App.Instance.Settings.SchoolPrefix.Value + "-Directie", false);
            staffGroup = AccountApi.Azure.GroupManager.Instance.FindGroupByName(State.App.Instance.Settings.SchoolPrefix.Value + "-Personeel", false);

            //secTeacherGroup = AccountApi.Azure.GroupManager.Instance.FindGroupByName(State.App.Instance.Settings.SchoolPrefix.Value + "-Leraren", true);
            secSupportGroup = AccountApi.Azure.GroupManager.Instance.FindGroupByName(State.App.Instance.Settings.SchoolPrefix.Value + "-Secretariaat", true);
            secDirectorGroup = AccountApi.Azure.GroupManager.Instance.FindGroupByName(State.App.Instance.Settings.SchoolPrefix.Value + "-Directie", true);
            secStaffGroup = AccountApi.Azure.GroupManager.Instance.FindGroupByName(State.App.Instance.Settings.SchoolPrefix.Value + "-Personeel", true);

            if (supportGroup == null 
                || directorGroup == null || staffGroup == null)
            {
                MainWindow.Instance.Log.AddError(Origin.Azure, "Niet alle personeelsgroepen werden gevonden");
            } else if (secSupportGroup == null
                || secDirectorGroup == null || secStaffGroup == null)
            {
                MainWindow.Instance.Log.AddError(Origin.Azure, "Niet alle veiligheidsgroepen werden gevonden");
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
