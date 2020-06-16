using AccountApi;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.Action.StaffAccount
{
    class AddToDirectory : AccountAction
    {
        public AddToDirectory() : base(
            "Maak een Nieuw Directory Account",
            "Voeg een account toe aan Active Directory.",
            true, true)
        {

        }

        public async override Task Apply(State.Linked.LinkedStaffMember linkedAccount)
        {
            var wisa = linkedAccount.Wisa.Account;
            var smartschool = linkedAccount.Smartschool.Account;

            var usernameExists = await AccountApi.Directory.AccountManager.Exists(smartschool.UID).ConfigureAwait(false);

            var directory = await AccountApi.Directory.AccountManager.Create(
                wisa.FirstName,
                wisa.LastName,
                wisa.CODE,
                AccountRole.Teacher,
                "",
                usernameExists ? "" : smartschool.UID
            ).ConfigureAwait(false);

            if (directory != null)
            {
                MainWindow.Instance.Log.AddMessage(Origin.Directory, "Added account for " + wisa.FirstName + " " + wisa.LastName);
            }
            else
            {
                MainWindow.Instance.Log.AddError(Origin.Directory, "Failed to add " + wisa.FirstName + " " + wisa.LastName);
            }
        }

        public static void Evaluate(State.Linked.LinkedStaffMember account)
        {
            if (account.Wisa.Exists && !account.Directory.Exists && account.Smartschool.Exists)
            {
                account.Actions.Add(new AddToDirectory());
            }
        }
    }
}
