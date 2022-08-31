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
                linkedAccount.Azure.Account = new AccountApi.Azure.User(user);
                MainWindow.Instance.Log.AddMessage(Origin.Azure, "Added account for " + user.DisplayName);
            }
            else
            {
                MainWindow.Instance.Log.AddError(Origin.Azure, "Failed to add " + linkedAccount.Wisa.Account.FirstName + " " + linkedAccount.Wisa.Account.LastName);
            }

            //var group = AccountApi.Azure.GroupManager.Instance.FindGroupByName(State.App.Instance.Settings.SchoolPrefix.Value + "-Leraren", false);
            //if (group != null)
            //{
            //    if (!group.HasMember(linkedAccount.Azure.Account))
            //    {
            //        await group.AddMember(linkedAccount.Azure.Account).ConfigureAwait(false);
            //    }
            //} else
            //{
            //    MainWindow.Instance.Log.AddError(Origin.Azure, "Group " + State.App.Instance.Settings.SchoolPrefix.Value + "-Leraren not found");
            //}

            var secgroup = AccountApi.Azure.GroupManager.Instance.FindGroupByName(State.App.Instance.Settings.SchoolPrefix.Value + "-Leraren", true);
            if (secgroup != null)
            {
                if (!secgroup.HasMember(linkedAccount.Azure.Account))
                {
                    await secgroup.AddMember(linkedAccount.Azure.Account).ConfigureAwait(false);
                }
            }
            else
            {
                MainWindow.Instance.Log.AddError(Origin.Azure, "SecGroup " + State.App.Instance.Settings.SchoolPrefix.Value + "-Leraren not found");
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
