using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.Action
{
    class ModifyDirectoryData : AccountAction
    {
        public enum Fields
        {
            CommonName,
        }

        public List<Fields> List = new List<Fields>();

        public new string Description
        {
            get
            {
                string result = "De volgende velden zijn niet up to date in active directory: ";
                foreach (var field in List)
                {
                    result += field.ToString() + ", ";
                }
                result = result.Remove(result.Count() - 2, 2);
                result += ". Ze kunnen automatisch aangepast worden.";
                return result;
            }
        }

        public ModifyDirectoryData() : base(
            AccountActionType.ModifyDirectoryData,
            "Wijzig de Active Directory Gebruiker",
            "...",
            true, true)
        {

        }

        public override async Task Apply(LinkedAccount linkedAccount, DateTime deletionDate)
        {
            InProgress.Value = true;

            await Task.Run(() =>
            {
                foreach (var field in List)
                {
                    switch (field)
                    {
                        case Fields.CommonName:

                            linkedAccount.directoryAccount.CN = linkedAccount.directoryAccount.DesiredCN();
                            break;
                    }
                }
            });
            MainWindow.Instance.Log.AddMessage(AccountApi.Origin.Directory, "Actie uitgevoerd voor " + linkedAccount.directoryAccount.FullName);

            InProgress.Value = false;
        }
    }
}
