using AccountApi;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.Action.StudentAccount
{
    internal class AddToAzure : AccountAction
    {
        public AddToAzure() : base(
            "Maak een Nieuw Office365 Account",
            "Voeg een account toe aan Office365",
            true, true)
        { }

        public async override Task Apply(State.Linked.LinkedAccount linkedAccount, DateTime deletionDate)
        {
            var user = await AccountApi.Azure.UserManager.Instance.CreateStudent(linkedAccount.Wisa.Account).ConfigureAwait(false);
            if (user != null)
            {
                linkedAccount.Azure.Account = new AccountApi.Azure.User(user);
                MainWindow.Instance.Log.AddMessage(Origin.Azure, "Added account for " + user.DisplayName);
            }
            else
            {
                MainWindow.Instance.Log.AddError(Origin.Azure, "Failed to add " + linkedAccount.Wisa.Account.FullName);
            }
        }

        public static void Evaluate(State.Linked.LinkedAccount account)
        {
            if (account.Wisa.Exists && !account.Azure.Exists)
            {
                account.Actions.Add(new AddToAzure());
            }
        }
    }
}
