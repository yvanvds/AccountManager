using AccountApi;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.Action.StaffAccount
{
    internal class AddToSmartschool : AccountAction
    {
        public AddToSmartschool() : base(
            "Maak een Nieuw Smartschool Account",
            "Voeg een account toe aan SmartSchool.",
            true, false)
        {

        }

        public async override Task Apply(State.Linked.LinkedStaffMember linkedAccount)
        {
            var wisa = linkedAccount.Wisa.Account;
            var azure = linkedAccount.Azure.Account;
            var directory = linkedAccount.Directory.Account;

            var smartschool = new AccountApi.Smartschool.Account();
            var password = AccountApi.Password.Create();

            smartschool.UID = directory.UID;
            smartschool.Role = AccountRole.Teacher;
            smartschool.GivenName = azure.GivenName;
            smartschool.SurName = azure.Surname;
            smartschool.AccountID = directory.UID;
            smartschool.Gender = GenderType.Male;

            smartschool.Mail = azure.UserPrincipalName;

            var result = await AccountApi.Smartschool.AccountManager
                .Save(smartschool, password)
                .ConfigureAwait(false);

            if (!result)
            {
                MainWindow.Instance.Log.AddError(Origin.Smartschool, "Failed to add " + directory.FullName);
                return;
            }
            else
            {
                MainWindow.Instance.Log.AddMessage(Origin.Smartschool, "Added account for " + directory.FullName);

                var groupResult = await AccountApi.Smartschool.GroupManager.AddUserToGroup(smartschool, AccountApi.Smartschool.GroupManager.Root.Find("Leerkrachten")).ConfigureAwait(false);
                if (!groupResult)
                {
                    MainWindow.Instance.Log.AddError(Origin.Smartschool, "Failed to add " + directory.FullName + " to group " + "Leerkrachten");
                }
            }
        }

        public static void Evaluate(State.Linked.LinkedStaffMember account)
        {
            if (account.Wisa.Exists && !account.Smartschool.Exists && account.Azure.Exists && account.Directory.Exists)
            {
                account.Actions.Add(new AddToDirectoryAndSmartschool());
            }

        }
    }
}
