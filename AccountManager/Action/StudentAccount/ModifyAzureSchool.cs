using AccountApi.Azure;
using System;
using System.Threading.Tasks;

namespace AccountManager.Action.StudentAccount
{
    class ModifyAzureSchool : AccountAction
    {
        public ModifyAzureSchool() : base(
            "Wijzig de school in Azure",
            "De leerling zit niet in school " + State.App.Instance.Settings.SchoolPrefix,
            true,
            false
        )
        {
            CanShowDetails = false;
        }

        public async override Task Apply(State.Linked.LinkedAccount linkedAccount, DateTime deletionDate)
        {
            linkedAccount.Azure.Account.ChangeCompanyName(State.App.Instance.Settings.SchoolPrefix.Value);

            await UserManager.Instance.UpdateSchool(linkedAccount.Azure.Account).ConfigureAwait(false);
        }

        public static void Evaluate(State.Linked.LinkedAccount account)
        {
            // CompanyName might not be set for all accounts
            if (account.Azure.Account.CompanyName == null) return;

            if (!account.Azure.Account.CompanyName.Equals(State.App.Instance.Settings.SchoolPrefix.Value, StringComparison.InvariantCulture))
            {
                account.Azure.FlagWarning();
                account.Actions.Add(new ModifyAzureSchool());
                account.OK = false;
            }
        }
    }
}
