using AccountApi;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.Action.StaffAccount
{
    internal class AddToAzure : AccountAction
    {
        public AddToAzure() : base(
            "Maak een Nieuw Office365 Account",
            "Voeg een account toe aan Office365",
            true, true)
        { }

        public async override Task Apply(State.Linked.LinkedStaffMember linkedAccount)
        {
            var user = await AccountApi.Azure.UserManager.Instance.CreateStaffMember(linkedAccount.Wisa.Account).ConfigureAwait(false);
            if (user != null)
            {
                MainWindow.Instance.Log.AddMessage(Origin.Azure, "Added account for " + user.DisplayName);
            }
            else
            {
                MainWindow.Instance.Log.AddError(Origin.Azure, "Failed to add " + linkedAccount.Wisa.Account.FirstName + " " + linkedAccount.Wisa.Account.LastName);
            }
        }

        public static void Evaluate(State.Linked.LinkedStaffMember account)
        {
            if (account.Wisa.Exists && !account.Azure.Exists)
            {
                account.Actions.Add(new AddToAzure());
            }
        }
    }
}
