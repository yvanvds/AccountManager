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
            var azure = linkedAccount.Azure.Account;

            var smartschool = new AccountApi.Smartschool.Account();
            var password = Password.Create();

            smartschool.UID = AccountApi.Smartschool.AccountManager.CreateUID(azure.GivenName, azure.Surname);
            smartschool.Role = AccountRole.Teacher;
            smartschool.GivenName = azure.GivenName;
            smartschool.SurName = azure.Surname;
            smartschool.AccountID = linkedAccount.Wisa.Account.CODE;
            smartschool.Gender = GenderType.Female;
            smartschool.Fax = linkedAccount.Wisa.Account.WisaID;

            smartschool.Mail = azure.UserPrincipalName;

            var result = await AccountApi.Smartschool.AccountManager
                .Save(smartschool, password)
                .ConfigureAwait(false);

            if (!result)
            {
                MainWindow.Instance.Log.AddError(Origin.Smartschool, "Failed to add " + azure.DisplayName);
                return;
            }
            else
            {
                AccountApi.Smartschool.GroupManager.UIDs.Add(smartschool.UID);

                MainWindow.Instance.Log.AddMessage(Origin.Smartschool, "Added account for " + azure.DisplayName);

                var groupResult = await AccountApi.Smartschool.GroupManager.AddUserToGroup(smartschool, AccountApi.Smartschool.GroupManager.Root.Find("Leerkrachten")).ConfigureAwait(false);
                if (!groupResult)
                {
                    MainWindow.Instance.Log.AddError(Origin.Smartschool, "Failed to add " + azure.DisplayName + " to group " + "Leerkrachten");
                }

                groupResult = await AccountApi.Smartschool.GroupManager.RemoveUserFromGroup(smartschool, AccountApi.Smartschool.GroupManager.Root.Find("Leerlingen")).ConfigureAwait(false);
                if (!groupResult)
                {
                    MainWindow.Instance.Log.AddError(Origin.Smartschool, "Failed to remove " + azure.DisplayName + " from group " + "Leerlingen");
                }
            }
        }

        public static void Evaluate(State.Linked.LinkedStaffMember account)
        {
            if (account.Wisa.Exists && !account.Smartschool.Exists && account.Azure.Exists)
            {
                account.Actions.Add(new AddToSmartschool());
            }

        }
    }
}
