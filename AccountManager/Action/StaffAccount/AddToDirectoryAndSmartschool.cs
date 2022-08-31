using AccountApi;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.Action.StaffAccount
{
    internal class AddToDirectoryAndSmartschool : AccountAction
    {
        public AddToDirectoryAndSmartschool() : base(
            "Maak een Nieuw Wifi en Smartschool Account",
            "Voeg een account toe aan SmartSchool en Wifi.",
            true, false)
        {

        }

        public async override Task Apply(State.Linked.LinkedStaffMember linkedAccount)
        {
            bool connected = await State.App.Instance.AD.Connect().ConfigureAwait(false);
            if (!connected) return;
            var wisa = linkedAccount.Wisa.Account;
            var azure = linkedAccount.Azure.Account;
            var uid = await AccountApi.Directory.Connector.CreateNewID(azure.GivenName, azure.Surname).ConfigureAwait(false);

            var directory = await AccountApi.Directory.AccountManager.Create(
                azure.GivenName,
                azure.Surname,
                azure.UserPrincipalName,
                wisa.CODE,
                AccountApi.AccountRole.Teacher,
                "",
                uid
            ).ConfigureAwait(false);

            if (directory == null)
            {
                MainWindow.Instance.Log.AddError(Origin.Directory, "Failed to add " + wisa.FirstName + " " + wisa.LastName);
                return;
            }

            directory.CopyCode = getCopyCode();
            MainWindow.Instance.Log.AddMessage(Origin.Directory, "Added account for " + directory.FullName);

            var smartschool = new AccountApi.Smartschool.Account();
            var password = AccountApi.Password.Create();

            smartschool.UID = uid;
            smartschool.Role = AccountRole.Teacher;
            smartschool.GivenName = azure.GivenName;
            smartschool.SurName = azure.Surname;
            smartschool.AccountID = uid;
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
            if (account.Wisa.Exists && !account.Smartschool.Exists && account.Azure.Exists && !account.Directory.Exists)
            {
                account.Actions.Add(new AddToDirectoryAndSmartschool());
            }

        }

        private int getCopyCode()
        {
            var random = new Random();
            bool valid = false;
            int code = 0;
            while (!valid)
            {
                code = random.Next(1001, 9999);
                valid = true;
                foreach (var account in AccountApi.Directory.AccountManager.Staff)
                {
                    if (code == account.CopyCode) valid = false;
                }
            }
            return code;
        }
    }
}
