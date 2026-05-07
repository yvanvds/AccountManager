using AccountApi;
using AccountManager.State.Linked;
using AccountManager.Utils;
using Microsoft.Graph;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using System.Windows.Documents;

namespace AccountManager.Action.StaffAccount
{
    internal class RemoveFromAzure : AccountAction
    {
        public RemoveFromAzure() : base(
            "Verwijder Azure Account",
            "Dit account bestaat niet in Smartschool of Wisa. Mogelijk mag dit verwijderd worden.",
            true)
        {
            CanShowDetails = true;
        }

        public override FlowDocument GetDetails(LinkedStaffMember account)
        {
            var result = new FlowTableCreator(false);
            result.SetHeaders(new string[] { "Active Schools" });
            result.AddRow(new List<string>() { account.Azure.Account.Department });

            FlowDocument document = new FlowDocument();
            document.Blocks.Add(result.Create());

            return document;
        }

        public async override Task Apply(State.Linked.LinkedStaffMember account)
        {
            var name = account.Azure.Account.DisplayName;
            bool result = await AccountApi.Azure.UserManager.Instance.DeleteUser(account.Azure.Account).ConfigureAwait(false);
            if (result)
            {
                account.Azure.Account = null;
                MainWindow.Instance.Log.AddMessage(Origin.Azure, "Removed account for " + name);
            }
            else
            {
                MainWindow.Instance.Log.AddError(Origin.Azure, "Failed to remove " + name);
            }
        }

        public static void Evaluate(State.Linked.LinkedStaffMember account)
        {
            if (!account.Wisa.Exists && !account.Smartschool.Exists && account.Azure.Exists)
            {
                account.Actions.Add(new RemoveFromAzure());
            }
        }
    }
}
