using AccountApi;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.Action.StudentAccount
{
    internal class RemoveFromAzure : AccountAction
    {
        public RemoveFromAzure() : base(
            "Verwijder Azure Account",
            "Dit account bestaat niet in Smartschool en Wisa. Mogelijk mag dit verwijderd worden.",
            true)
        {

        }

        public async override Task Apply(State.Linked.LinkedAccount account, DateTime deletionDate)
        {
            var name = account.Azure.Account.DisplayName;
            bool result = await AccountApi.Azure.UserManager.Instance.DeleteUser(account.Azure.Account).ConfigureAwait(false);
            if (result)
            {
                MainWindow.Instance.Log.AddMessage(Origin.Azure, "Removed account for " + name);
            }
            else
            {
                MainWindow.Instance.Log.AddError(Origin.Azure, "Failed to remove " + name);
            }
        }

        public static void Evaluate(State.Linked.LinkedAccount account)
        {
            if (!account.Wisa.Exists && !account.Smartschool.Exists && account.Azure.Exists)
            {
                if (account.Azure.Account.CompanyName.Equals(State.App.Instance.Settings.SchoolPrefix.Value))
                {
                    // This is a old account, no longer linked to Wisa or Smartschool.
                    // It can be removed from Azure.
                    account.Actions.Add(new RemoveFromAzure());
                }
            }
        }
    }
}
